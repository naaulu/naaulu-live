FROM ubuntu:26.04 AS build

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential cmake git curl ca-certificates openssh-client \
    libhdf5-dev libnetcdf-dev \
    && rm -rf /var/lib/apt/lists/*

RUN curl -LsSf https://astral.sh/uv/install.sh | sh
ENV PATH="/root/.local/bin:$PATH"

ARG CACHEBUST=1
# Branch of the upstream naaulu repo to build against (CI passes `next` for the :next image)
ARG NAAULU_BRANCH=main
RUN git clone --branch "$NAAULU_BRANCH" https://git.naaulu.org/naaulu/naaulu.git /opt/naaulu
WORKDIR /opt/naaulu
RUN ./install.sh

# Bake the OSM boundary/city cache into the image: the pipeline is time
# critical, so runtime must never wait on a fetch. Defaults to every
# European country naaulu supports — 46 countries × 3 tiers ≈ 460 MB
# unpacked (~133 MB compressed transfer, ~15 min of Postpass queries at
# build). CI can narrow it with a comma-separated ISO3 list. The prefetch
# fails loudly if a tier cannot be filled — a broken build beats a plot
# that stalls on its first run.
ARG NAAULU_BOUNDARIES="ALA,ALB,AND,AUT,BEL,BIH,BGR,HRV,CYP,CZE,DNK,EST,FIN,FRA,DEU,GRC,GGY,HUN,ISL,IRL,ITA,JEY,LVA,LIE,LTU,LUX,MLT,MDA,MCO,MNE,MKD,NLD,NOR,POL,PRT,ROU,SMR,SRB,SVK,SVN,ESP,SWE,CHE,TUR,GBR,UKR"
# mv (not cp): same filesystem in the build stage, so the bake costs one
# copy, not two; /opt/naaulu-boundaries must stay OUTSIDE
# /root/.local/share/naaulu because the declared volume shadows image
# content at that path — the entrypoint seeds the volume from here.
RUN if [ -n "$NAAULU_BOUNDARIES" ]; then \
        /opt/naaulu/.venv/bin/python prefetch_boundaries.py \
            "$NAAULU_BOUNDARIES" --levels ADM0,ADM2,CITIES \
        && mv /root/.local/share/naaulu/boundaries /opt/naaulu-boundaries; \
    else \
        mkdir -p /opt/naaulu-boundaries; \
    fi

FROM ubuntu:26.04

RUN apt-get update && apt-get install -y --no-install-recommends \
    openssh-client ca-certificates sshpass \
    && rm -rf /var/lib/apt/lists/*

COPY --from=build /opt/naaulu /opt/naaulu
COPY --from=build /root/.local/share/uv/python /root/.local/share/uv/python
# Pristine boundary cache, kept OUTSIDE /root/.local/share/naaulu on purpose:
# an existing named volume shadows image content at the mount point, so the
# entrypoint seeds the volume from this copy.
COPY --from=build /opt/naaulu-boundaries /opt/naaulu-boundaries

ENV PATH="/opt/naaulu/.venv/bin:$PATH" \
    VIRTUAL_ENV="/opt/naaulu/.venv" \
    PYTHON_GIL=0

COPY config.sh run.sh deploy.sh entrypoint.sh /opt/naaulu-live/
RUN chmod +x /opt/naaulu-live/run.sh /opt/naaulu-live/deploy.sh /opt/naaulu-live/entrypoint.sh

VOLUME ["/root/.cache/naaulu", "/root/.local/share/naaulu"]

ENTRYPOINT ["/opt/naaulu-live/entrypoint.sh"]
