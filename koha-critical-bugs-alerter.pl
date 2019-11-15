#!/usr/bin/env perl

use Modern::Perl;

use Carp::Always;
use Data::Dumper;
use DateTime;
use File::Slurp;
use Getopt::Long::Descriptive;
use JSON qw(to_json from_json);
use LWP::UserAgent;
use Template;
use Term::ANSIColor;
use Try::Tiny;
use WebService::Mailgun;

my $tt = Template->new({
    INCLUDE_PATH => '.',
    INTERPOLATE  => 1,
}) || die "$Template::ERROR\n";

my ( $opt, $usage ) = describe_options(
    'tracker-updater.pl',
    [ "community-url=s", "Community tracker URL", { required => 1, default => $ENV{KOHA_URL} } ],
    [],
    [ 'slack|s=s', "Slack webhook URL", { required => 0, default => $ENV{KCBA_SLACK_URL} } ],
    [],
    [ 'mailgun-api-key|mak=s', "Mailgun API key", { required => 0, default => $ENV{MAILGUN_API_KEY} } ],
    [ 'mailgun-api-domain|mad=s', "Mailgun API domain", { required => 0, default => $ENV{MAILGUN_API_DOMAIN} } ],
    [],
    [ 'email-to|to|t=s', "Address to send email to", { required => 0, default => $ENV{EMAIL_TO} } ],
    [ 'email-from|from|f=s', "Address from send email from", { required => 0, default => $ENV{EMAIL_FROM} } ],
    [],
    [ 'verbose|v+', "Print extra stuff", { required => 1, default => 0 } ],
    [ 'help|h', "Print usage message and exit", { shortcircuit => 1 } ],
);

print( $usage->text ), exit if $opt->help;

my $bz_koha_url = $opt->community_url || 'https://bugs.koha-community.org/bugzilla3';

my $ua = LWP::UserAgent->new;
$ua->post(
    $opt->slack,
    Content_Type => 'application/json',
    Content => to_json( { text => "Running critical Koha bugs alerter!" } ),
) if $opt->slack;
say colored( 'Getting criticals!', 'green' );

# Koha BZ is on GMT time
my $today = DateTime
      ->now( time_zone => 'GMT' )
      ->truncate( to => 'day' )
      ->strftime('%Y-%m-%d');
my $yesterday = DateTime
      ->now( time_zone => 'GMT' )
      ->truncate( to => 'day' )
      ->subtract( days => 1 )
      ->strftime('%Y-%m-%d');
my $last_24hrs = DateTime
      ->now( time_zone => 'GMT' )
      ->subtract( hours => 25 )
      ->strftime('%Y-%m-%dT%H-%M-%SZ');
say colored( "Today: $today", "cyan" ) if $opt->verbose > 1;
say colored( "Yesterday: $yesterday", "cyan" ) if $opt->verbose > 1;
say colored( "25 Hours Ago: $last_24hrs", "cyan" ) if $opt->verbose > 1;

my $bugs_seen = {};
my @bugs_to_keep;
for my $s (qw( critical blocker )) {
    for my $d ( $today, $yesterday ) {
        my $url      = "$bz_koha_url/rest/bug?severity=$s&last_change_time=$d";
        my $response = $ua->get($url);
        my $content  = $response->decoded_content;
        my $json     = from_json($content);

        my @bugs = @{ $json->{bugs} };
        next unless @bugs;

        foreach my $bug (@bugs) {
            next if $bugs_seen->{ $bug->{id} };

            say colored( "Looking at bug $bug->{id}.", 'yellow' )
              if $opt->verbose > 1;

            if ( $bug->{last_change_time} ge $last_24hrs ) {
                $url = "$bz_koha_url/rest/bug/$bug->{id}/history";
                $response = $ua->get($url);
                $content  = $response->decoded_content;
                $json     = from_json($content);

                my @history = @{$json->{bugs}->[0]->{history}};
                my @slack_fields;
                my @history_to_keep;
                foreach my $h (@history) {
                    if ( $h->{when} ge $last_24hrs ) {

                        my @changes_to_keep;
                        foreach my $c ( @{ $h->{changes} } ) {
                            next if $c->{field_name} eq 'cc';
                            next if $c->{field_name} eq 'attachments.isobsolete';
                            next if $c->{field_name} eq 'keywords';

                            my $cli_msg;
                            my $slack_msg;
                            if ( $c->{removed} && $c->{added} ) {
                                $cli_msg = "Bug $bug->{id}: `$h->{who}` changed `$c->{field_name}` from `$c->{removed}` to `$c->{added}`";
                                $slack_msg = "`$h->{who}` changed `$c->{field_name}` from `$c->{removed}` to `$c->{added}`";
                                push( @slack_fields, { short => JSON::false, title => "Changed", value => $slack_msg } );
                            }
                            elsif ( $c->{removed} ) {
                                $cli_msg = "Bug $bug->{id}: `$h->{who}` removed `$c->{removed}` from `$c->{field_name}`";
                                $slack_msg = "`$h->{who}` removed `$c->{removed}` from `$c->{field_name}`";
                                push( @slack_fields, { short => JSON::false, title => "Removed", value => $slack_msg } );
                            }
                            else {
                                $cli_msg = "Bug $bug->{id}: `$h->{who}` added `$c->{added}` to `$c->{field_name}`";
                                $slack_msg = "`$h->{who}` added `$c->{added}` to `$c->{field_name}`";
                                push( @slack_fields, { short => JSON::false, title => "Added", value => $slack_msg } );
                            }

                            say Data::Dumper::Dumper($c) if $opt->verbose > 2;
                            say colored( $cli_msg, "white" );
                            push( @changes_to_keep, $c );
                        }

                        $h->{changes} = \@changes_to_keep;
                        push( @history_to_keep, $h );
                    }
                }

                $bug->{history} = \@history_to_keep;
                push( @bugs_to_keep, $bug );
                $bugs_seen->{ $bug->{id} } = 1;

                my $json_data = {
                    "attachments" => [
                        {
                            title => "<$bz_koha_url/show_bug.cgi?id=$bug->{id}|Bug $bug->{id}>",
                            #pretext => "Pretext _supports_ mrkdwn",
                            text => $bug->{summary},
                            fields => \@slack_fields,
                            mrkdwn_in => [ "text", "pretext", "fields" ],
                        }
                    ]
                };
                my $json_text = to_json( $json_data );
                $ua->post(
                    $opt->slack,
                    Content_Type => 'application/json',
                    Content      => $json_text,
                ) if $opt->slack;
            }
        }
    }
}

if (   $opt->mailgun_api_key
    && $opt->mailgun_api_domain
    && $opt->email_to
    && $opt->email_from )
{
    say colored("Sending email!", 'cyan') if $opt->verbose > 1;

    my $vars = {
        bugs        => \@bugs_to_keep,
        bz_koha_url => $bz_koha_url,
    };

    $tt->process( 'email.tt', $vars, 'email.html' )
      || die $tt->error(), "\n";
    qx{ tidy -o email.html email.html };
    my $html = read_file('email.html');

    my $mailgun = WebService::Mailgun->new(
        api_key => $opt->mailgun_api_key,
        domain  => $opt->mailgun_api_domain,
    );

    # send mail
    my $ymd = DateTime->now()->ymd();
    my $res = $mailgun->message(
        {
            from    => $opt->email_from,
            to      => $opt->email_to,
            subject => "Changes to Critical Koha Bugs ( $ymd )",
            html    => $html,
        }
    );

    say colored("Email sent!", 'cyan') if $opt->verbose > 1;
}

$ua->post(
    $opt->slack,
    Content_Type => 'application/json',
    Content => to_json( { text => "Critial Koha bugs alerter has finished running!" } ),
) if $opt->slack;
say colored( 'Finished!', 'green' );
