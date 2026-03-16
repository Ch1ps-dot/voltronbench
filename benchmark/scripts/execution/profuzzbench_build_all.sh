#!/bin/bash

#export NO_CACHE="--no-cache"
#export MAKE_OPT="-j4"

cd $PFBENCH
cd subjects/DNS/Dnsmasq
docker build . -t Dnsmsqs --build-arg MAKE_OPT $NO_CACHE

cd subjects/DTLS/TinyDTLS
docker build . -t TinyDTLS-vol --build-arg MAKE_OPT $NO_CACHE

cd subjects/SSH/OpenSSH
docker build . -t OpenSSH --build-arg MAKE_OPT $NO_CACHE

cd subjects/TLS/OpenSSL
docker build . -t OpenSSL --build-arg MAKE_OPT $NO_CACHE

cd subjects/FTP/LightFTP
docker build . -t lightftp-vol --build-arg MAKE_OPT $NO_CACHE

cd $PFBENCH
cd subjects/FTP/BFTPD
docker build . -t bftpd-vol --build-arg MAKE_OPT $NO_CACHE

cd $PFBENCH
cd subjects/FTP/ProFTPD
docker build . -t proftpd-vol --build-arg MAKE_OPT $NO_CACHE

cd $PFBENCH
cd subjects/FTP/PureFTPD
docker build . -t pure-ftpd-vol --build-arg MAKE_OPT $NO_CACHE

cd $PFBENCH
cd subjects/SMTP/Exim
docker build . -t exim-vol --build-arg MAKE_OPT $NO_CACHE

cd $PFBENCH
cd subjects/RTSP/Live555
docker build . -t live555-vol --build-arg MAKE_OPT $NO_CACHE

cd $PFBENCH
cd subjects/SIP/Kamailio
docker build . -t kamailio-vol --build-arg MAKE_OPT $NO_CACHE

cd $PFBENCH
cd subjects/DAAP/forked-daapd
docker build . -t forked-daapd-vol --build-arg MAKE_OPT $NO_CACHE

cd $PFBENCH
cd subjects/HTTP/Lighttpd1
docker build . -t lighttpd1-vol --build-arg MAKE_OPT $NO_CACHE
