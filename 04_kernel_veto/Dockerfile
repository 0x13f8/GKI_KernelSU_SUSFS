FROM ubuntu:22.04
RUN apt-get update -qq && \
    apt-get install -y -qq \
      git curl python3 cpio bc bison flex libssl-dev xz-utils zstd \
      lld llvm clang ccache libelf-dev patch rsync kmod file gawk wget make \
      ca-certificates --no-install-recommends && \
    curl -s https://storage.googleapis.com/git-repo-downloads/repo > /usr/local/bin/repo && \
    chmod a+x /usr/local/bin/repo && \
    git config --global user.name "b" && \
    git config --global user.email "b@l" && \
    apt-get clean
