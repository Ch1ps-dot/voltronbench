FROM ubuntu:20.04

# Install common dependencies
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get -y update && \
    apt-get -y install sudo \ 
    apt-utils \
    build-essential \
    openssl \
    clang \
    graphviz-dev \
    git \
    autoconf \
    libgnutls28-dev \
    libssl-dev \
    llvm \
    python3-pip \
    nano \
    net-tools \
    vim \
    gdb \
    netcat \
    strace \
    libcap-dev \
    libpcre2-dev \
    libpcre2-8-0 \
    libcurl4-openssl-dev \
    libjson-c-dev \
    pkg-config \
    zlib1g-dev \
    automake libtool m4 \
    wget

# Add a new user ubuntu, pass: ubuntu
RUN groupadd ubuntu && \
    useradd -rm -d /home/ubuntu -s /bin/bash -g ubuntu -G sudo -u 1000 ubuntu -p "$(openssl passwd -1 ubuntu)"

RUN chmod 777 /tmp

RUN pip3 install gcovr==4.2

# Use ubuntu as default username
USER ubuntu
WORKDIR /home/ubuntu

COPY --chown=ubuntu:ubuntu voltron voltron
RUN pip install uv -i https://pypi.tuna.tsinghua.edu.cn/simple
ENV PATH="/home/ubuntu/.local/bin:$PATH"
ENV UV_PYTHON_INSTALL_MIRROR=https://mirrors.ustc.edu.cn/github-release/astral-sh/python-build-standalone/
RUN cd voltron && \
    uv sync 

ENV WORKDIR="/home/ubuntu/experiments"
RUN mkdir $WORKDIR

COPY --chown=ubuntu:ubuntu reproduce.patch ${WORKDIR}/reproduce.patch

RUN cd $WORKDIR && \
    git clone https://github.com/rovinbhandari/FTP.git FTP && \
    cd FTP && \
    patch -p1 < ${WORKDIR}/reproduce.patch && \
    make