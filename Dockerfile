FROM ubuntu:16.04

MAINTAINER Hugo Beauzée-Luyssen <hugo@beauzee.fr>

#FIXME: Remove vim once debuging is complete
RUN apt-get update -qq && apt-get install -qqy \
    git wget bzip2 file libwine-development-dev unzip libtool pkg-config cmake \
    build-essential automake texinfo ragel yasm p7zip-full gettext autopoint \
    vim python


RUN git config --global user.name "VideoLAN Buildbot" && \
    git config --global user.email buildbot@videolan.org

WORKDIR /build

RUN git clone -b release_39 https://github.com/llvm-mirror/llvm.git --depth=1
RUN cd llvm/tools && \
    git clone -b release_39 --depth=1 https://github.com/llvm-mirror/clang.git && \
    git clone --depth=1 -b release_39 https://github.com/llvm-mirror/lld.git --depth=1

#RUN cd llvm/projects && \
#    git clone -b release_39 --depth=1 https://github.com/llvm-mirror/libcxx.git && \
#    git clone -b release_39 --depth=1 https://github.com/llvm-mirror/libcxxabi.git && \
#    git clone https://github.com/llvm-mirror/libunwind.git -b release_39 --depth=1

RUN mkdir /build/patches

COPY patches/llvm-*.patch patches/clang-*.patch patches/lld-*.patch /build/patches/

RUN cd llvm && \
    git am /build/patches/llvm-*.patch

RUN cd llvm/tools/clang && \
    git am /build/patches/clang-*.patch

RUN cd llvm/tools/lld && \
    git am /build/patches/lld-*.patch

#RUN cd llvm/projects/libcxx && \
#    git am /build/patches/libcxx-*.patch

RUN mkdir /build/prefix

# Build LLVM
RUN cd llvm && mkdir build && cd build && cmake \
    -DCMAKE_INSTALL_PREFIX="/build/prefix" \
    -DCMAKE_BUILD_TYPE=Release \
    -DLLVM_ENABLE_ASSERTIONS=OFF \
    -DLLVM_ENABLE_EH=ON \
    -DLLVM_ENABLE_THREADS=ON \
    -DLLVM_ENABLE_RTTI=ON \
    -DLLVM_ENABLE_FFI=OFF \
    -DLLVM_ENABLE_SPHINX=OFF \
    -DCMAKE_CXX_FLAGS="-D_GNU_SOURCE -D_LIBCPP_HAS_NO_CONSTEXPR" \
    ../ && \
    make -j4 && \
    make install

RUN git clone --depth=1 git://git.code.sf.net/p/mingw-w64/mingw-w64
COPY patches/mingw-*.patch /build/patches/
RUN cd mingw-w64 && \
    git am /build/patches/mingw-*.patch

#FIXME: Move this UP!
ENV TOOLCHAIN_PREFIX=/build/prefix
ENV TARGET_TUPLE=armv7-w64-mingw32
ENV MINGW_PREFIX=$TOOLCHAIN_PREFIX/$TARGET_TUPLE
ENV PATH=$TOOLCHAIN_PREFIX/bin:$PATH

RUN mkdir $MINGW_PREFIX
RUN ln -s $MINGW_PREFIX $TOOLCHAIN_PREFIX/mingw

RUN cd mingw-w64/mingw-w64-headers && mkdir build && cd build && \
    ../configure --host=$TARGET_TUPLE --prefix=$MINGW_PREFIX \
        --enable-secure-api && \
    make install

# Install the usual $TUPLE-clang binary
COPY wrappers/* $TOOLCHAIN_PREFIX/bin/

ENV CC=armv7-w64-mingw32-clang
ENV CXX=armv7-w64-mingw32-clang++
ENV AR=llvm-ar 
ENV RANLIB=llvm-ranlib 
ENV LD=lld
ENV AS=llvm-as
ENV NM=llvm-nm

# Build mingw with our freshly built cross compiler
# Since somewhere between llvm 3.8 and 3.9, SVN rev 273373, git mirror commit
# d319cd64a4a15,, llvm-ar tries to detect the format (gnu vs bsd) of the
# existing .a file. For files generated by genlib, it seems to detect the
# wrong format, leading to lld later segfaulting when trying to link.
# Force the flag -format gnu to llvm-ar in this step to work around this issue.
RUN cd mingw-w64/mingw-w64-crt && \
    autoreconf -vif && \
    mkdir build && cd build && \
    AR="llvm-ar -format gnu" ../configure --host=$TARGET_TUPLE --prefix=$MINGW_PREFIX \
        --disable-lib32 --disable-lib64 --enable-libarm32 \
        --with-genlib=llvm-dlltool && \
    make -j4 && \
    make install

RUN cp /build/mingw-w64/mingw-w64-libraries/winpthreads/include/* $MINGW_PREFIX/include/

RUN git clone -b master --depth=1 https://github.com/llvm-mirror/compiler-rt.git

# Manually build compiler-rt as a standalone project
RUN cd compiler-rt && mkdir build && cd build && cmake \
    -DCMAKE_C_COMPILER=$CC \
    -DCMAKE_CXX_COMPILER=$CXX \
    -DCMAKE_SYSTEM_NAME=Windows \
    -DCMAKE_AR=$TOOLCHAIN_PREFIX/bin/$AR \
    -DCMAKE_RANLIB=$TOOLCHAIN_PREFIX/bin/$RANLIB \
    -DCMAKE_C_COMPILER_WORKS=1 \
    -DLLVM_CONFIG_PATH=$TOOLCHAIN_PREFIX/bin/llvm-config \
    -DCOMPILER_RT_DEFAULT_TARGET_TRIPLE="armv7--windows-gnu" \
    -DCMAKE_SIZEOF_VOID_P=4 \
    ../lib/builtins && \
    make -j4 && \
    mkdir -p /build/prefix/lib/clang/3.9.1/lib/windows && \
    cp lib/windows/libclang_rt.builtins-arm.a /build/prefix/lib/clang/3.9.1/lib/windows

RUN cd mingw-w64/mingw-w64-libraries && cd winstorecompat && \
    autoreconf -vif && \
    mkdir build && cd build && \
    ../configure --host=$TARGET_TUPLE --prefix=$MINGW_PREFIX && make && make install

RUN cd /build/mingw-w64/mingw-w64-tools/widl && \
    mkdir build && cd build && \
    CC=gcc \
    ../configure --prefix=$TOOLCHAIN_PREFIX --target=$TARGET_TUPLE && \
    make -j4 && \
    make install 

RUN git clone -b release_39 --depth=1 https://github.com/llvm-mirror/libcxx.git && \
    git clone -b release_39 --depth=1 https://github.com/llvm-mirror/libcxxabi.git && \
    git clone -b release_39 --depth=1 https://github.com/llvm-mirror/libunwind.git

COPY patches/libcxx-*.patch /build/patches/
RUN cd libcxx && \
    git am /build/patches/libcxx-*.patch

COPY patches/libcxxabi-*.patch /build/patches/
RUN cd libcxxabi && \
    git am /build/patches/libcxxabi-*.patch

# COPY patches/libunwind-*.patch /build/patches/
#RUN cd libunwind && \
#    git am /build/patches/libunwind-*.patch

RUN cd libunwind && mkdir build && cd build && \
    CXXFLAGS="-nodefaultlibs -D_LIBUNWIND_IS_BAREMETAL" \
    LDFLAGS="/build/prefix/armv7-w64-mingw32/lib/crt2.o /build/prefix/armv7-w64-mingw32/lib/crtbegin.o -lmingw32 /build/prefix/bin/../lib/clang/3.9.1/lib/windows/libclang_rt.builtins-arm.a -lmoldname -lmingwex -lmsvcrt -ladvapi32 -lshell32 -luser32 -lkernel32 /build/prefix/armv7-w64-mingw32/lib/crtend.o" \
    cmake \
        -DCMAKE_CXX_COMPILER_WORKS=TRUE \
        -DLLVM_ENABLE_LIBCXX=TRUE \
        -DCMAKE_BUILD_TYPE=Release \
        -DLIBUNWIND_ENABLE_SHARED=OFF \
        ..

#RUN cd libunwind/build && make -j4
#RUN cd libunwind/build && make install

RUN cd libcxx && mkdir build && cd build && \
    cmake \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=$TOOLCHAIN_PREFIX/$TARGET_TUPLE \
        -DCMAKE_C_COMPILER=$CC \
        -DCMAKE_CXX_COMPILER=$CXX \
        -DCMAKE_CROSSCOMPILING=TRUE \
        -DCMAKE_SYSTEM_NAME=Windows \
        -DCMAKE_C_COMPILER_WORKS=TRUE \
        -DCMAKE_CXX_COMPILER_WORKS=TRUE \
        -DCMAKE_AR=$TOOLCHAIN_PREFIX/bin/$AR \
        -DCMAKE_RANLIB=$TOOLCHAIN_PREFIX/bin/$RANLIB \
        -DLIBCXX_INSTALL_HEADERS=ON \
        -DLIBCXX_ENABLE_EXCEPTIONS=OFF \
        -DLIBCXX_ENABLE_THREADS=OFF \
        -DLIBCXX_ENABLE_MONOTONIC_CLOCK=OFF \
        -DLIBCXX_ENABLE_SHARED=OFF \
        -DLIBCXX_SUPPORTS_STD_EQ_CXX11_FLAG=TRUE \
        -DLIBCXX_HAVE_CXX_ATOMICS_WITHOUT_LIB=TRUE \
        -DLIBCXX_ENABLE_EXPERIMENTAL_LIBRARY=OFF \
        -DLIBCXX_ENABLE_FILESYSTEM=OFF \
        -DLIBCXX_ENABLE_STATIC_ABI_LIBRARY=TRUE \
        -DLIBCXX_CXX_ABI=libcxxabi \
        -DLIBCXX_CXX_ABI_INCLUDE_PATHS=../../libcxxabi/include \
        -DCMAKE_CXX_FLAGS="-fno-exceptions" \
        .. && \
    make -j4 && \
    make install

RUN cd libcxxabi && mkdir build && cd build && \
    cmake \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=$TOOLCHAIN_PREFIX/$TARGET_TUPLE \
        -DCMAKE_C_COMPILER=$CC \
        -DCMAKE_CXX_COMPILER=$CXX \
        -DCMAKE_CROSSCOMPILING=TRUE \
        -DCMAKE_SYSTEM_NAME=Windows \
        -DCMAKE_C_COMPILER_WORKS=TRUE \
        -DCMAKE_CXX_COMPILER_WORKS=TRUE \
        -DCMAKE_AR=$TOOLCHAIN_PREFIX/bin/$AR \
        -DCMAKE_RANLIB=$TOOLCHAIN_PREFIX/bin/$RANLIB \
        -DLIBCXXABI_USE_COMPILER_RT=ON \
        -DLIBCXXABI_ENABLE_EXCEPTIONS=OFF \
        -DLIBCXXABI_ENABLE_THREADS=OFF \
        -DLIBCXXABI_TARGET_TRIPLE=$TARGET_TUPLE \
        -DLIBCXXABI_SYSROOT=$TOOLCHAIN_PREFIX/$TARGET_TUPLE \
        -DLIBCXXABI_ENABLE_SHARED=OFF \
        -DLIBCXXABI_LIBCXX_INCLUDES=$TOOLCHAIN_PREFIX/$TARGET_TUPLE/c++/v1 \
        -DLLVM_NO_OLD_LIBSTDCXX=TRUE \
        -DCXX_SUPPORTS_CXX11=TRUE \
        -DCMAKE_CXX_FLAGS="-fno-exceptions" \
        .. && \
    make -j4 && \
    make install

RUN cd /build/prefix/include && ln -s /build/prefix/$TARGET_TUPLE/include/c++ .

RUN mkdir gaspp && cd gaspp && \
    wget -q https://raw.githubusercontent.com/libav/gas-preprocessor/master/gas-preprocessor.pl && \
    chmod +x gas-preprocessor.pl

ENV PATH=/build/gaspp:$PATH

ENV AS="gas-preprocessor.pl ${CC}"
ENV ASCPP="gas-preprocessor.pl ${CC}"
ENV CCAS="gas-preprocessor.pl ${CC}"
ENV LDFLAGS="-lmsvcr120_app ${LDFLAGS}"

RUN mkdir -p /build/hello
COPY hello.c hello.cpp /build/hello/
RUN cd /build/hello && armv7-w64-mingw32-clang hello.c -o hello.exe
RUN cd /build/hello && armv7-w64-mingw32-clang++ hello.cpp -o hello-cpp.exe -fno-exceptions

RUN git clone --depth=1 git://git.libav.org/libav.git

# Clear LDFLAGS, lld seems to fail with msvcr120_app for some reason (recheck this)
RUN cd /build/libav && \
    mkdir build && cd build && \
    LDFLAGS="" ../configure --arch=arm --cpu=armv7-a --target-os=mingw32 --cc=armv7-w64-mingw32-clang --ar=llvm-ar --nm=llvm-nm --enable-cross-compile --enable-gpl && \
    make -j4 all testprogs
