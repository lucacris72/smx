FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive
ARG XPACK_VERSION=15.2.0-1
ARG XPACK_ARCHIVE=xpack-riscv-none-elf-gcc-15.2.0-1-linux-x64.tar.gz

ENV RISCV=/opt/riscv
ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1
ENV PATH=/opt/smx-env/bin:/opt/riscv/bin:/usr/local/bin:${PATH}

LABEL org.opencontainers.image.title="SMX Docker Environment"
LABEL org.opencontainers.image.description="Reproducible container environment for the SMX CV32E40P softmax accelerator project"
LABEL org.opencontainers.image.source="https://github.com/lucacris72/smx"

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    build-essential \
    ca-certificates \
    curl \
    git \
    make \
    python-is-python3 \
    python3 \
    python3-pip \
    python3-venv \
    tar \
    verilator \
    && rm -rf /var/lib/apt/lists/*

COPY python-requirements.txt /tmp/python-requirements.txt
COPY riscv32-unknown-elf-gcc /usr/local/bin/riscv32-unknown-elf-gcc

RUN python3 -m venv /opt/smx-env \
    && /opt/smx-env/bin/pip install --upgrade pip setuptools wheel \
    && /opt/smx-env/bin/pip install --no-cache-dir -r /tmp/python-requirements.txt

RUN mkdir -p /opt/riscv/bin \
    && mkdir -p /opt/riscv/riscv32-unknown-elf \
    && curl -fsSL -o /tmp/${XPACK_ARCHIVE} \
        https://github.com/xpack-dev-tools/riscv-none-elf-gcc-xpack/releases/download/v${XPACK_VERSION}/${XPACK_ARCHIVE} \
    && tar -xzf /tmp/${XPACK_ARCHIVE} -C /opt/riscv --strip-components=1 \
    && ln -sf /opt/riscv/bin/riscv-none-elf-gcc /opt/riscv/bin/riscv32-unknown-elf-gcc.real \
    && ln -sf /opt/riscv/bin/riscv-none-elf-objcopy /opt/riscv/bin/riscv32-unknown-elf-objcopy \
    && ln -sf /opt/riscv/bin/riscv-none-elf-objdump /opt/riscv/bin/riscv32-unknown-elf-objdump \
    && ln -sfn /opt/riscv/riscv-none-elf/include /opt/riscv/riscv32-unknown-elf/include \
    && multidir="$("/opt/riscv/bin/riscv-none-elf-gcc" -march=rv32imc_zicsr -mabi=ilp32 -print-multi-directory)" \
    && gccdir="$(echo /opt/riscv/lib/gcc/riscv-none-elf/*)" \
    && ln -sfn "${gccdir}/${multidir}" /opt/riscv/riscv32-unknown-elf/lib \
    && chmod +x /usr/local/bin/riscv32-unknown-elf-gcc \
    && ln -sf /usr/local/bin/riscv32-unknown-elf-gcc /opt/riscv/bin/riscv32-unknown-elf-gcc \
    && rm -f /tmp/${XPACK_ARCHIVE}

WORKDIR /workspace

CMD ["bash"]
