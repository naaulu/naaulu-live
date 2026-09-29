FROM ubuntu:26.04 AS build

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential cmake git curl ca-certificates openssh-client \
    libhdf5-dev libnetcdf-dev \
    && rm -rf /var/lib/apt/lists/*

RUN curl -LsSf https://astral.sh/uv/install.sh | sh
ENV PATH="/root/.local/bin:$PATH"

ARG CACHEBUST=1
RUN git clone https://git.naaulu.org/naaulu/naaulu.git /opt/naaulu
WORKDIR /opt/naaulu
RUN ./install.sh

FROM ubuntu:26.04

RUN apt-get update && apt-get install -y --no-install-recommends \
    openssh-client ca-certificates sshpass \
    && rm -rf /var/lib/apt/lists/*

COPY --from=build /opt/naaulu /opt/naaulu
COPY --from=build /root/.local/share/uv/python /root/.local/share/uv/python

ENV PATH="/opt/naaulu/.venv/bin:$PATH" \
    VIRTUAL_ENV="/opt/naaulu/.venv" \
    PYTHON_GIL=0

COPY config.sh run.sh deploy.sh entrypoint.sh /opt/naaulu-live/
RUN chmod +x /opt/naaulu-live/run.sh /opt/naaulu-live/deploy.sh /opt/naaulu-live/entrypoint.sh

VOLUME ["/root/.cache/naaulu", "/root/.local/share/naaulu"]

ENTRYPOINT ["/opt/naaulu-live/entrypoint.sh"]
