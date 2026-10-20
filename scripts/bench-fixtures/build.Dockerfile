# Compiles git from the extracted source, which is the build context.
FROM dockma-bench-tools
COPY . /src
RUN make -C /src -j"$(nproc)" NO_OPENSSL=1 NO_CURL=1 NO_EXPAT=1 NO_GETTEXT=1 NO_TCLTK=1 NO_PERL=1 NO_PYTHON=1 NO_REGEX=NeedsStartEnd git
