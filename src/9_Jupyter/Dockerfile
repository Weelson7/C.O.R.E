FROM quay.io/jupyter/base-notebook:python-3.11

USER root

# Install Java, unzip, and build dependencies for xeus-cling
RUN apt-get update && apt-get install -y \
    openjdk-17-jdk \
    wget \
    unzip \
    && rm -rf /var/lib/apt/lists/*

USER ${NB_UID}

# Install IJava kernel
RUN wget https://github.com/SpencerPark/IJava/releases/download/v1.3.0/ijava-1.3.0.zip && \
    unzip ijava-1.3.0.zip -d ijava-kernel && \
    cd ijava-kernel && \
    python3 install.py --sys-prefix && \
    cd .. && \
    rm -rf ijava-kernel ijava-1.3.0.zip

# Install xeus-cling (C++ kernel) via conda
RUN mamba install -y -c conda-forge xeus-cling && \
    mamba clean --all -f -y

# Verify kernels are installed
RUN jupyter kernelspec list

USER ${NB_UID}
WORKDIR "${HOME}"
