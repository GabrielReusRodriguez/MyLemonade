# ==============================================================
# # 1. Lemonade builder — compile lemonade C++ binaries
# # ============================================================

# Chuleta ./lemonade  --host 127.0.0.1 run --llamacpp-args "--verbose --fit off -mlock" --llamacpp rocm --llamacpp-device ROCm0 
FROM ubuntu:24.04 AS lemonade_builder
#FROM rocm/dev-ubuntu-24.04 as builder

# Avoid interactive prompts during build
ENV DEBIAN_FRONTEND=noninteractive

# Install build dependencies
RUN apt-get update && apt-get install -y \
    build-essential \
    cmake \
    libssl-dev \
    pkg-config \
    git \
    libdrm-dev \
    && rm -rf /var/lib/apt/lists/*


# Copy source code
WORKDIR /app
#RUN git clone --depth 1 --single-branch https://github.com/lemonade-sdk/lemonade.git
COPY ./lemonade /app/lemonade

WORKDIR /app/lemonade
# Build the project

#RUN rm -rf build && \
#    mkdir -p build && \
#    cd build && \ 
#    cmake --build --preset default \
#    cmake .. && \
#    cmake --build . --config Release -j"$(nproc)"

# Ejecuto el script que se encarga de las dependencias y le paso CI = true  par que asuma que le digo que si a todo.
#RUN CI=true ./setup.sh

RUN mkdir -p build
RUN cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
RUN cmake --build  build --config Release  -j"$(nproc)"

# Debug: Check build outputs
RUN echo "=== Build directory contents ===" && \
    ls -la build/ && \
    echo "=== Checking for resources ===" && \
    find build/ -name "*.json" -o -name "resources" -type d

# # ============================================================
# # 2. FastFlowLLM  builder- 
# # ============================================================

FROM ubuntu:24.04 AS fastflowlm_builder

# Basado en el Dockerfile del repositorio oficial https://github.com/FastFlowLM/FastFlowLM.git
# Primero instalo las dependencias.
LABEL org.opencontainers.image.description="FastFlowLM build environment with all dependencies pre-installed"
LABEL org.opencontainers.image.source="https://github.com/FastFlowLM/FastFlowLM"

# Prevent interactive prompts during installation
ENV DEBIAN_FRONTEND=noninteractive
ARG UBUNTU_PPA=""
ARG BACKPORTS=""

# Set up PPA if needed
RUN if [ -n "$UBUNTU_PPA" ]; then \
        apt update && apt install -y software-properties-common && \
        add-apt-repository -y "$UBUNTU_PPA"; \
    fi

# setup backports if needed
RUN if [ -n "$BACKPORTS" ]; then \
        echo "deb http://deb.debian.org/debian $BACKPORTS main" >> /etc/apt/sources.list; \
        apt update; \
        apt install -t $BACKPORTS -y libxrt-dev; \
    fi

# Install all build dependencies
RUN apt update && apt install -y  \
    build-essential \
    cargo \
    cmake \
    debhelper-compat \
    dpkg-dev \
    fakeroot \
    git \
    libavcodec-dev \
    libavformat-dev \
    libavutil-dev \
    libboost-dev \
    libboost-program-options-dev \
    libcurl4-openssl-dev \
    libdrm-dev \
    libfftw3-dev \
    libreadline-dev \
    libswresample-dev \
    libswscale-dev \
    nasm \
    ninja-build \
    patchelf \
    pkg-config \
    uuid-dev \
    curl \
    software-properties-common \
    && rm -rf /var/lib/apt/lists/*

RUN add-apt-repository ppa:lemonade-team/stable
RUN apt update
RUN apt install -y libxrt-dev libxrt-npu2 amdxdna-dkms


# 2. Corregir enlace simbólico (limpio, apuntando al directorio raíz de cabeceras)
#RUN mkdir -p /opt/xilinx/xrt && \
#    ln -s /usr/include /opt/xilinx/xrt/include

# Necesito el restc 1.85 y los repositorios de apt tienen hasta el 1.75 asi que lo instalo por separado.
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh  -s -- -y && \
    . "$HOME/.cargo/env" && \
    rustup toolchain install 1.85 && \
    rustup default 1.85


WORKDIR /app

# Ahora voy a compilarlo.

# Clonamos el repositorio.
#RUN git clone --depth 1 --recursive --single-branch https://github.com/FastFlowLM/FastFlowLM.git
COPY ./FastFlowLM/ /app/FastFlowLM
WORKDIR /app/FastFlowLM/src

# Configuramos la compilacion
# Con --preset linux-default, se instalará en /opt/fastflolm
#RUN cmake --preset linux-default -DXRT_INCLUDE_DIR=/opt/xilinx/xrt/include
#RUN cmake --preset linux-default -DXRT_INCLUDE_DIR=/usr/include/xrt/ 
#RUN cmake --preset linux-default -DXRT_INCLUDE_DIR=/usr/include/xrt/ -DCMAKE_CXX_FLAGS="-I/usr/include/"
RUN cmake --preset linux-default

# Compilo
RUN cmake --build build -j$(nproc)

# OPCIONAL:  instalamos el proyecto
RUN cmake --install build


# # ============================================================
# # 4. Runtime stage — small, clean image
# # ============================================================

#rocm/dev-ubuntu-24.04:latest
#FROM rocm/dev-ubuntu-24.04:latest
FROM ubuntu:24.04

# Install runtime dependencies only
RUN apt-get update && apt-get install -y \
    libcurl4 \
    curl \
    libssl3 \
    zlib1g \
    vulkan-tools \
    libvulkan1 \
    unzip \
    libgomp1 \
    libatomic1 \
    libwebsockets-dev \
    software-properties-common \
    && rm -rf /var/lib/apt/lists/*

#    hipblas-dev     \

# Create application directory
WORKDIR /app/lemonade

# Copy built executables and resources from builder
COPY --from=lemonade_builder /app/lemonade/build/lemond /app/lemonade/lemond
COPY --from=lemonade_builder /app/lemonade/build/lemonade /app/lemonade/lemonade
COPY --from=lemonade_builder /app/lemonade/build/resources /app/lemonade/resources

# Make executables executable
#RUN chmod +x /app/lemonade/lemond /app/lemonade/lemonade

# Create necessary directories
#RUN mkdir -p /opt/lemonade/llama/cpu \
#    /opt/lemonade/llama/vulkan \
#    /opt/lemonade/.cache/huggingface

# Expose default port
EXPOSE 13305

# Health ch=eck
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:13305/live || exit 1


# Instalamos FastFlowLm
#COPY --from=fastflowlm_builder /app/FastFlowLM/ /app/lemonade/apk/
#WORKDIR /app/apk/
#RUN wget https://github.com/FastFlowLM/FastFlowLM/releases/download/v0.9.43/fastflowlm_0.9.43_ubuntu24.04_amd64.deb
#RUN curl -fL -o /tmp/fastflowlm.deb "https://github.com/FastFlowLM/FastFlowLM/releases/download/v0.9.43/fastflowlm_0.9.43_ubuntu24.04_amd64.deb"  && \
#       apt install -y /tmp/fastflowlm.deb 


RUN add-apt-repository ppa:lemonade-team/stable
RUN apt update
RUN apt install -y \
        libxrt-dev \
        libxrt-npu2 \
        amdxdna-dkms \
        libavformat-dev \
        libswscale-dev \
        libavcodec-dev \
        libavformat-dev \
        libavutil-dev \
        libboost-dev \
        libboost-program-options-dev \
        libcurl4-openssl-dev \
        libdrm-dev \
        libfftw3-dev \
        libreadline-dev \
        libswresample-dev \
        &&  rm -rf /var/lib/apt/lists/*


# Copiamos la compilacion de FastFlowLM
COPY --from=fastflowlm_builder /opt/fastflowlm /app/fastflowlm
RUN ln -s /app/fastflowlm/bin/flm /usr/local/bin/flm
# Configuramos lemonade con los backends necesarios.

# --- TRUCO DE PRE-DESCARGA ---
# Definimos temporalmente las rutas de XDG DENTRO de la imagen (sin volúmenes todavía)
#ENV XDG_CACHE_HOME=/app/lemonade/built_in/.cache
#ENV XDG_DATA_HOME=/app/lemonade/built_in/.data
#ENV LEMONADE_CACHE_DIR=/app/lemonade/built_in/.cache/lemonade
#ENV XDG_RUNTIME_DIR=/tmp


# Forzamos a Lemonade a descargar y "preparar" los entornos de ROCm y CPU.
# Ejecutamos comandos de listado o pre-carga que activan el trigger de descarga del backend.
# ./lemonade backends install llamacpp:rocm
#RUN ./lemonade backends install llamacpp:rocm  || true
#RUN ./lemonade backends install llamacpp:cpu   || true
#RUN ./lemonade backends install kokoro:cpu     || true
#RUN ./lemonade backends install sd-cpp:cpu     || true
#RUN ./lemonade backends install sd-cpp:rocm    || true
#RUN ./lemonade backends install vllm:rocm      || true
#RUN ./lemonade backends install whisper:cpu    || true

# Las npus se instalan a parte.

#RUN ./lemonade models list --backend rocm || true
#RUN ./lemonade models list --backend cpu || true

#COPY ./entrypoint.sh /app/lemonade/entrypoint.sh
#RUN chmod +x /app/lemonade/entrypoint.sh
#RUN ls -la /app/lemonade/ && file /app/lemonade/lemond || true
# Default command: start server in headless mode

# Si quiero la RDNA4 , he debajarme el llama.cpp compilado expreesametne de la web: https://github.com/lemonade-sdk
# Ya que lo que baja la web es la rocm SIN soporte para gpus.
# en concreto : https://github.com/lemonade-sdk/llamacpp-rocm/releases/download/b1287/llama-b1287-ubuntu-rocm-gfx120X-x64.zip

# Instalamos la compilación de llama.cpp tuneada.
#COPY --from=llamacpp_builder /opt/* /opt/
#RUN mkdir -p /opt/llama.cpp/
#COPY --from=llamacpp_builder /app/llama.cpp/build/bin/ /opt/llama.cpp/

#RUN mkdir -p /app/lemonade/cfg/
#VOLUME /app/lemonade/cfg/
#COPY ./config/config.json /app/lemonade/cfg/config.json
#COPY ./config/recipe_options.json /app/lemonade/cfg/recipe_options.json
#COPY ./config/resources /app/lemonade/cfg/resources/

WORKDIR /app/lemonade

#CMD ["/app/lemonade/lemond"]
#CMD ["/app/lemonade/lemond", "--host", "0.0.0.0"]
ENV PATH="/app/lemonade/:${PATH}"
#ENTRYPOINT ["/app/lemonade/entrypoint.sh"]
CMD ["lemond", "--host", "0.0.0.0"]
