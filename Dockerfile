# install python packages
ARG BASE_IMAGE=ubuntu:22.04
FROM ubuntu:22.04 AS python_pkg_provider
RUN apt-get -qq update && \
    apt-get -qq install python3 python3-pip build-essential
COPY ./config/requirements.txt /tmp/requirements.txt
RUN pip3 install --upgrade pip wheel && \
    pip3 install --user -r /tmp/requirements.txt -f "https://download.pytorch.org/whl/torch_stable.html"

# main stage
FROM ubuntu:22.04 AS base
ARG PYTHON_VERSION=3.11

ARG USERNAME="user"
ARG TZ="Asia/Taipei"


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
    locales \
    nano \
    tree \
    vim \
    emacs

FROM ${BASE_IMAGE} as dev-base


RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends curl

RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        ccache \
        cmake \
        git \
        libjpeg-dev \
        apt-utils \
        sudo \
        wget \
        software-properties-common \
        libpng-dev && \
    apt-get -qq update && \
    apt-get -qq upgrade && \
    apt-get -qq install -y ${DEVELOPMENT_PACKAGES} ${TOOL_PACKAGES} && \
    rm -rf /var/lib/apt/lists/*


RUN /usr/sbin/update-ccache-symlinks
RUN mkdir /opt/ccache && ccache --set-config=cache_dir=/opt/ccache
ENV PATH /opt/conda/bin:$PATH

FROM dev-base as conda
ARG PYTHON_VERSION=3.11
# Automatically set by buildx
ARG TARGETPLATFORM
# translating Docker's TARGETPLATFORM into miniconda arches
RUN case ${TARGETPLATFORM} in \
         "linux/arm64")  MINICONDA_ARCH=aarch64  ;; \
         *)              MINICONDA_ARCH=x86_64   ;; \
    esac && \
    curl -fsSL -v -o ~/miniconda.sh -O  "https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-${MINICONDA_ARCH}.sh"

# Manually invoke bash on miniconda script per https://github.com/conda/conda/issues/10431
RUN chmod +x ~/miniconda.sh && \
    bash ~/miniconda.sh -b -p /opt/conda && \
    rm ~/miniconda.sh && \
    /opt/conda/bin/conda install -y python=${PYTHON_VERSION} cmake conda-build pyyaml numpy ipython && \
    /opt/conda/bin/conda clean -ya

FROM dev-base as submodule-update
WORKDIR /opt/pytorch
COPY . .
RUN git submodule update --init --recursive

FROM conda as build
ARG CMAKE_VARS
WORKDIR /opt/pytorch
COPY --from=conda /opt/conda /opt/conda
COPY --from=submodule-update /opt/pytorch /opt/pytorch
RUN make triton
RUN --mount=type=cache,target=/opt/ccache \
    export eval ${CMAKE_VARS} && \
    TORCH_CUDA_ARCH_LIST="7.0 7.2 7.5 8.0 8.6 8.7 8.9 9.0 9.0a" TORCH_NVCC_FLAGS="-Xfatbin -compress-all" \
    CMAKE_PREFIX_PATH="$(dirname $(which conda))/../" \
    python setup.py install

FROM conda as conda-installs
ARG PYTHON_VERSION=3.11
ARG CUDA_VERSION=12.1
ARG CUDA_CHANNEL=nvidia
ARG INSTALL_CHANNEL=pytorch-nightly
# Automatically set by buildx
# Note conda needs to be pinned to 23.5.2 see: https://github.com/pytorch/pytorch/issues/106470
RUN /opt/conda/bin/conda install -c "${INSTALL_CHANNEL}" -y python=${PYTHON_VERSION} conda=23.5.2
ARG TARGETPLATFORM

# On arm64 we can only install wheel packages.
RUN case ${TARGETPLATFORM} in \
         "linux/arm64")  pip install --extra-index-url https://download.pytorch.org/whl/cpu/ torch torchvision torchaudio ;; \
         *)              /opt/conda/bin/conda install -c "${INSTALL_CHANNEL}" -c "${CUDA_CHANNEL}" -y "python=${PYTHON_VERSION}" pytorch torchvision torchaudio "pytorch-cuda=$(echo $CUDA_VERSION | cut -d'.' -f 1-2)"  ;; \
    esac && \
    /opt/conda/bin/conda clean -ya
RUN /opt/conda/bin/pip install torchelastic

FROM ${BASE_IMAGE} as official
ARG PYTORCH_VERSION
ARG TRITON_VERSION
ARG TARGETPLATFORM
ARG CUDA_VERSION
LABEL com.nvidia.volumes.needed="nvidia_driver"
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ca-certificates \
        libjpeg-dev \
        libpng-dev \
        && rm -rf /var/lib/apt/lists/*
COPY --from=conda-installs /opt/conda /opt/conda
RUN if test -n "${TRITON_VERSION}" -a "${TARGETPLATFORM}" != "linux/arm64"; then \
        DEBIAN_FRONTEND=noninteractive apt install -y --no-install-recommends gcc; \
        rm -rf /var/lib/apt/lists/*; \
    fi
ENV PATH /opt/conda/bin:$PATH
ENV NVIDIA_VISIBLE_DEVICES all
ENV NVIDIA_DRIVER_CAPABILITIES compute,utility
ENV LD_LIBRARY_PATH /usr/local/nvidia/lib:/usr/local/nvidia/lib64
ENV PATH /usr/local/nvidia/bin:/usr/local/cuda/bin:$PATH
ENV PYTORCH_VERSION ${PYTORCH_VERSION}



ENV USER "${USERNAME}"
ENV TERM xterm-256color
ENV APT_KEY_DONT_WARN_ON_DANGEROUS_USAGE DontWarn

# set env var JAVA_HOME
ENV JAVA_HOME "/usr/lib/jvm/java-8-openjdk-*"

# setup time zone
RUN ln -snf /usr/share/zoneinfo/${TZ} /etc/localtime && echo ${TZ} > /etc/timezone

WORKDIR /home
RUN apt-get clean && apt-get update && apt-get install -y locales dos2unix
RUN touch /etc/locale.gen

# add support of locale zh_TW
RUN sed -i 's/# en_US.UTF-8/en_US.UTF-8/g' /etc/locale.gen && \
    sed -i 's/# zh_TW.UTF-8/zh_TW.UTF-8/g' /etc/locale.gen && \
    sed -i 's/# zh_TW BIG5/zh_TW BIG5/g' /etc/locale.gen && \
    locale-gen && \
    dpkg-reconfigure --frontend=noninteractive locales && \
    update-locale LANG=en_US.UTF-8 && \
    update-locale LC_ALL=en_US.UTF-8
ENV LC_ALL en_US.UTF-8

ARG UID=1000
ARG GID=1000
ARG USERNAME="user"
RUN mkdir /etc/sudoers.d
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
    mkdir -p /home/"${USERNAME}"/projects && \
    mkdir -p /home/"${USERNAME}"/.local
RUN chown -R ${UID}:${GID} /home/"${USERNAME}"

# install python libraries
RUN pip3 install --upgrade pip wheel
COPY --from=python_pkg_provider --chown=${UID}:${GID} /root/.local /home/"${USERNAME}"/.local

ENV PATH="${PATH}:/home/${USERNAME}/.local/bin"

# TensorBoard setup
EXPOSE 10000

USER "${USERNAME}"

WORKDIR /home/"${USERNAME}"

CMD [ "bash", "/docker/start.sh" ]
