FROM perl

WORKDIR /app

# Copy all files to workdir
COPY . .

RUN cpanm --notest --installdeps .

RUN apt-get -y update \
    && apt-get -y install \
       tidy \
    && rm -rf /var/cache/apt/archives/* \
    && rm -rf /var/lib/api/lists/*

CMD ./koha-critical-bugs-alerter.pl -v -v
