# install python packages
# https://github.com/iot-salzburg/gpu-jupyter
FROM nvidia/cuda:12.4.0-base-ubuntu22.04
RUN apt-get -qq update && \
    apt-get -qq install python3 python3-pip build-essential

# install python libraries
RUN pip3 install --upgrade pip wheel

ARG UID=1000
ARG GID=1000
ARG USERNAME="user"
ARG TZ="Asia/Taipei"

# reference from https://github.com/ContinuumIO/docker-images/blob/main/miniconda3/debian/Dockerfile
# also from https://github.com/anibali/docker-pytorch
# the template steam from playlab
ENV INSTALLATION_TOOLS apt-utils \
    bzip2 \
    ca-certificates \
    git \
    libglib2.0-0 \
    libsm6 \
    libxext6 \
    libxrender1 \
    mercurial \
    openssh-client \
    procps \
    subversion \
    wget \
    sudo \
    curl \
    wget \
    zstd \
    software-properties-common

ENV DEVELOPMENT_PACKAGES python3 \
    python3-pip \
    python-is-python3 \
    build-essential \
    valgrind \
    make \
    gdb \
    ca-certificates-java \
    openjdk-8-jdk

ENV TOOL_PACKAGES bash \
    dos2unix \
    git \
    locales \
    nano \
    tree \
    vim \
    emacs

ENV USER "${USERNAME}"
ENV TERM xterm-256color
ENV APT_KEY_DONT_WARN_ON_DANGEROUS_USAGE DontWarn

# install system packages
RUN apt-get -qq update && \
    apt-get -qq install ${INSTALLATION_TOOLS} && \
    # start install
    apt-get -qq update && \
    apt-get -qq upgrade && \
    apt-get -qq install ${DEVELOPMENT_PACKAGES} ${TOOL_PACKAGES} \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# env for the executorch, not we only specified the 7_18 version since the latest version failed = =
RUN apt-get -qq update && \
    apt-get -qq install clang && \
    wget https://github.com/facebook/buck2/releases/download/2023-07-18/buck2-x86_64-unknown-linux-musl.zst && \
    zstd -cdq buck2-x86_64-unknown-linux-musl.zst  > /tmp/buck2 && chmod +x /tmp/buck2 && \
    mv /tmp/buck2 /usr/local/bin/buck2 && \
    rm -rf /tmp/buck2 && \
    apt-get clean


# set env var JAVA_HOME
ENV JAVA_HOME "/usr/lib/jvm/java-8-openjdk-*"

RUN git clone --branch v0.1.0 https://github.com/pytorch/executorch.git
RUN cd executorch && git submodule sync && git submodule update --init
RUN mkdir -p /home/${USERNAME}/projects


# install conda
ARG TARGETARCH
RUN if [ [ "${TARGETARCH}" = "arm64" ] ]; then \
    wget https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-aarch64.sh -O /tmp/miniconda.sh; \
    else \
    wget https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh -O /tmp/miniconda.sh; \
    fi

RUN /bin/bash /tmp/miniconda.sh -b -p /opt/conda

RUN set -x && \
    ln -s /opt/conda/etc/profile.d/conda.sh /etc/profile.d/conda.sh && \
    echo ". /opt/conda/etc/profile.d/conda.sh" >> ~/.bashrc && \
    echo "conda activate base" >> ~/.bashrc && \
    find /opt/conda/ -follow -type f -name '*.a' -delete && \
    find /opt/conda/ -follow -type f -name '*.js.map' -delete && \
    /opt/conda/bin/conda clean -afy

ENV PATH /opt/conda/bin:$PATH

# install python libraries
SHELL ["/bin/bash", "--login", "-c"]
COPY ./config/conda_requirements.txt /tmp/requirements.txt
# from https://blog.csdn.net/weixin_41978699/article/details/122294459
# setup pytorch virtualenv
# downgrade to fit the tutorial for EXECUTORCH
RUN conda create -n torch -y python=3.10;

# from https://pythonspeed.com/articles/activate-conda-dockerfile/
SHELL ["conda", "run", "--no-capture-output", "-n", "torch", "/bin/bash", "-c"]
RUN conda activate torch; \
    conda install cmake && \
    pip3 install --upgrade pip && \
    pip3 install torch torchvision torchaudio &&\
    pip3 install -r /tmp/requirements.txt; \
    conda deactivate; \
    rm /tmp/requirements.txt


RUN echo "alias run-jupyter=\"jupyter notebook --NotebookApp.iopub_data_rate_limit=1.0e10 --ip 0.0.0.0 --port 8888 --no-browser --allow-root >jupyter.stdout.log &>jupyter.stderr.log &\" " >> /opt/conda/etc/profile.d/conda.sh

# setup time zone
RUN ln -snf /usr/share/zoneinfo/${TZ} /etc/localtime && echo ${TZ} > /etc/timezone

# add support of locale zh_TW
RUN sed -i 's/# en_US.UTF-8/en_US.UTF-8/g' /etc/locale.gen && \
    sed -i 's/# zh_TW.UTF-8/zh_TW.UTF-8/g' /etc/locale.gen && \
    sed -i 's/# zh_TW BIG5/zh_TW BIG5/g' /etc/locale.gen && \
    locale-gen && \
    dpkg-reconfigure --frontend=noninteractive locales && \
    update-locale LANG=en_US.UTF-8 && \
    update-locale LC_ALL=en_US.UTF-8

# add non-root user account
RUN groupadd -o -g ${GID} "${USERNAME}" && \
    useradd -u ${UID} -m -s /bin/bash -g ${GID} "${USERNAME}" && \
    echo "${USERNAME} ALL = NOPASSWD: ALL" > /etc/sudoers.d/"${USERNAME}" && \
    chmod 0440 /etc/sudoers.d/"${USERNAME}" && \
    passwd -d "${USERNAME}"

# add scripts and setup permissions
COPY --chown=${UID}:${GID} ./scripts/.bashrc /home/"${USERNAME}"/.bashrc
COPY --chown=${UID}:${GID} ./scripts/start.sh /docker/start.sh
COPY --chown=${UID}:${GID} ./scripts/login.sh /docker/login.sh
COPY --chown=${UID}:${GID} ./scripts/startup.sh /usr/local/bin/startup
RUN dos2unix -ic "/home/${USERNAME}/.bashrc" | xargs dos2unix && \
    dos2unix -ic "/docker/start.sh" | xargs dos2unix && \
    dos2unix -ic "/docker/login.sh" | xargs dos2unix && \
    dos2unix -ic "/usr/local/bin/startup" | xargs dos2unix && \
    chmod +x "/usr/local/bin/startup"

# user account configuration
RUN mkdir -p /home/"${USERNAME}"/.ssh && \
    mkdir -p /home/"${USERNAME}"/.vscode-server && \
    mkdir -p /home/"${USERNAME}"/.local
RUN chown -R ${UID}:${GID} /home/"${USERNAME}"

WORKDIR /home/${USERNAME}/projects
RUN cp -r /executorch/ /home/${USERNAME}/projects
RUN pwd && ls -alhs
WORKDIR /home/${USERNAME}/projects/executorchls
#build environment for executorch
RUN conda create -yn executorch python=3.10.0;

RUN source activate executorch; \
    conda install cmake && \
    ./install_requirements.sh 2>/dev/null || true && \
    pip3 install --upgrade pip && \
    conda deactivate
WORKDIR /

ENV PATH="${PATH}:/home/${USERNAME}/.local/bin"

# TensorBoard setup
EXPOSE 10000

USER "${USERNAME}"
WORKDIR /home/"${USERNAME}"
CMD [ "bash", "/docker/start.sh" ]

