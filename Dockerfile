FROM perl

WORKDIR /app

# Copy all files to workdir
COPY . .

RUN cpanm --installdeps . 

CMD ./koha-critical-bugs-alerter.pl -v
