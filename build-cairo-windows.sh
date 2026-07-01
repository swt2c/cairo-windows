#! bash
set -e
trap 'previous_command=$this_command; this_command=$BASH_COMMAND' DEBUG
trap 'echo FAILED COMMAND: $previous_command' EXIT

# Versions used
USE_FREETYPE=1
CAIRO_VERSION=cairo-1.15.12
PIXMAN_VERSION=pixman-0.34.0
LIBPNG_VERSION=libpng-1.6.35
ZLIB_VERSION=zlib-1.2.11
FREETYPE_VERSION=freetype-2.9.1

# Set variables according to command line argument
if [ ${1:-x86} = x64 ]; then
    MSVC_PLATFORM_NAME=x64
    OUTPUT_PLATFORM_NAME=x64
elif [ ${1:-x86} = arm64 ]; then
    MSVC_PLATFORM_NAME=ARM64
    OUTPUT_PLATFORM_NAME=arm64
else
    MSVC_PLATFORM_NAME=Win32
    OUTPUT_PLATFORM_NAME=x86
fi

# Make sure the MSVC linker appears first in the path. MSYS2 ships its own
# /usr/bin/link.exe (a hardlink utility, unrelated to MSVC's linker), which
# can shadow the real one depending on PATH order, so derive the MSVC bin
# directory from cl.exe (unambiguous) rather than parsing `whereis link`.
MSVC_BIN_DIR=`dirname "$(command -v cl)"`
export PATH="$MSVC_BIN_DIR:$PATH"

# Download packages if not already
wget -nc https://www.cairographics.org/snapshots/$CAIRO_VERSION.tar.xz
wget -nc https://www.cairographics.org/releases/$PIXMAN_VERSION.tar.gz
wget -nc https://download.sourceforge.net/libpng/$LIBPNG_VERSION.tar.gz
wget -nc https://www.zlib.net/fossils/$ZLIB_VERSION.tar.gz
if [ $USE_FREETYPE -ne 0 ]; then
    wget -nc https://download.sourceforge.net/freetype/$FREETYPE_VERSION.tar.gz
fi    

# Extract packages if not already
if [ ! -d cairo ]; then
    echo "Extracting $CAIRO_VERSION..."
    tar -xJf $CAIRO_VERSION.tar.xz
    mv $CAIRO_VERSION cairo
fi
if [ ! -d pixman ]; then
    echo "Extracting $PIXMAN_VERSION..."
    tar -xzf $PIXMAN_VERSION.tar.gz
    mv $PIXMAN_VERSION pixman
fi
if [ ! -d libpng ]; then
    echo "Extracting $LIBPNG_VERSION..."
    tar -xzf $LIBPNG_VERSION.tar.gz
    mv $LIBPNG_VERSION libpng
fi
if [ ! -d zlib ]; then
    echo "Extracting $ZLIB_VERSION..."
    tar -xzf $ZLIB_VERSION.tar.gz
    mv $ZLIB_VERSION zlib
fi
if [ $USE_FREETYPE -ne 0 ] && [ ! -d freetype ]; then
    echo "Extracting $FREETYPE_VERSION..."
    tar -xzf $FREETYPE_VERSION.tar.gz
    mv $FREETYPE_VERSION freetype
fi

# Build libpng and zlib
if [ $MSVC_PLATFORM_NAME = ARM64 ]; then
    # The vendored vstudio.sln/vcxproj files predate ARM64 platform support
    # and only declare Win32/x64 configurations, so they can't be pointed at
    # ARM64 without hand-editing project files. Both libpng and zlib ship
    # their own CMakeLists.txt which already understands ARM64 (via
    # `cmake -A ARM64`), so use that instead for this platform only.
    # cairo/pixman are linked with the static CRT (/MT, via the -MD -> -MT sed
    # below), so these CMake builds must use the same static CRT or the final
    # link fails with unresolved __imp_* CRT symbols from a /MD <-> /MT mismatch.
    cd zlib
    cmake -S . -B build-arm64 -G "Visual Studio 17 2022" -A ARM64 -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DCMAKE_POLICY_DEFAULT_CMP0091=NEW -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded
    cmake --build build-arm64 --config Release --target zlibstatic
    cd ..
    cp zlib/build-arm64/Release/*.lib zlib/zlib.lib
    cp zlib/build-arm64/zconf.h zlib/zconf.h

    cd libpng
    cmake -S . -B build-arm64 -G "Visual Studio 17 2022" -A ARM64 -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DCMAKE_POLICY_DEFAULT_CMP0091=NEW -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded \
        -DPNG_SHARED=OFF -DPNG_TESTS=OFF -DPNG_EXECUTABLES=OFF \
        -DZLIB_INCLUDE_DIR="$(pwd)/../zlib" -DZLIB_LIBRARY="$(pwd)/../zlib/zlib.lib"
    cmake --build build-arm64 --config Release --target png_static
    cd ..
    cp libpng/build-arm64/Release/*.lib libpng/libpng.lib
    # cairo's Makefile.win32.common expects pnglibconf.h next to png.h in the
    # source tree; CMake generates it into the out-of-source build dir instead.
    cp libpng/build-arm64/pnglibconf.h libpng/pnglibconf.h
else
    cd libpng
    sed s/zlib-1.2.8/zlib/ projects/vstudio/zlib.props > zlib.props.fixed
    mv zlib.props.fixed projects/vstudio/zlib.props
    if [ ! -d "projects\vstudio\Backup" ]; then
        # Upgrade solution if not already
        devenv.com "projects\vstudio\vstudio.sln" -upgrade
    fi
    devenv.com "projects\vstudio\vstudio.sln" -build "Release Library|$MSVC_PLATFORM_NAME" -project libpng
    cd ..
    if [ $MSVC_PLATFORM_NAME = x64 ]; then
        cp "libpng/projects/vstudio/x64/Release Library/libpng16.lib" libpng/libpng.lib
        cp "libpng/projects/vstudio/x64/Release Library/zlib.lib" zlib/zlib.lib
    else
        cp "libpng/projects/vstudio/Release Library/libpng16.lib" libpng/libpng.lib
        cp "libpng/projects/vstudio/Release Library/zlib.lib" zlib/zlib.lib
    fi
fi

# Build pixman
cd pixman
sed s/-MD/-MT/ Makefile.win32.common > Makefile.win32.common.fixed
mv Makefile.win32.common.fixed Makefile.win32.common
if [ $MSVC_PLATFORM_NAME = ARM64 ]; then
    # MMX/SSE2/SSSE3 are all x86-only instruction sets. Makefile.win32.common
    # predates ARM64 and defaults SSE2/SSSE3 to "on" unconditionally, so they
    # must be turned off explicitly here or it'll try to build pixman-sse2.c
    # for a target that has no SSE.
    make pixman -B -f Makefile.win32 "CFG=release" "MMX=off" "SSE2=off" "SSSE3=off"
elif [ $MSVC_PLATFORM_NAME = x64 ]; then
    # pass -B for switching between x86/x64
    make pixman -B -f Makefile.win32 "CFG=release" "MMX=off"
else
    make pixman -B -f Makefile.win32 "CFG=release"
fi
cd ..

if [ $USE_FREETYPE -ne 0 ]; then
    cd freetype
    if [ $MSVC_PLATFORM_NAME = ARM64 ]; then
        # Same story as libpng/zlib above: the vc2010 solution has no ARM64
        # platform, but freetype's own CMakeLists.txt supports it directly.
        cmake -S . -B build-arm64 -G "Visual Studio 17 2022" -A ARM64 -DCMAKE_BUILD_TYPE=Release \
            -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DCMAKE_POLICY_DEFAULT_CMP0091=NEW -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded \
            -DBUILD_SHARED_LIBS=OFF -DFT_DISABLE_HARFBUZZ=ON -DFT_DISABLE_BROTLI=ON \
            -DFT_DISABLE_BZIP2=ON -DFT_DISABLE_PNG=ON -DFT_DISABLE_ZLIB=ON
        cmake --build build-arm64 --config Release --target freetype
        cp build-arm64/Release/*.lib freetype.lib
    else
        # Build freetype
        if [ ! -d "builds/windows/vc2010/Backup" ]; then
            # Upgrade solution if not already
            devenv.com "builds/windows/vc2010/freetype.sln" -upgrade
        fi
        devenv.com "builds/windows/vc2010/freetype.sln" -build "Release Static|$MSVC_PLATFORM_NAME"
        cp "`ls -1d "objs/$MSVC_PLATFORM_NAME/Release Static/freetype.lib"`" .
    fi
    cd ..
fi

# Build cairo
cd cairo
sed 's/-MD/-MT/;s/zdll.lib/zlib.lib/' build/Makefile.win32.common > Makefile.win32.common.fixed
mv Makefile.win32.common.fixed build/Makefile.win32.common
if [ $USE_FREETYPE -ne 0 ]; then
    sed '/^CAIRO_LIBS =/s/$/ $(top_builddir)\/..\/freetype\/freetype.lib/;/^DEFAULT_CFLAGS =/s/$/ -I$(top_srcdir)\/..\/freetype\/include/' build/Makefile.win32.common > Makefile.win32.common.fixed
else
    sed '/^CAIRO_LIBS =/s/ $(top_builddir)\/..\/freetype\/freetype.lib//;/^DEFAULT_CFLAGS =/s/ -I$(top_srcdir)\/..\/freetype\/include//' build/Makefile.win32.common > Makefile.win32.common.fixed
fi
mv Makefile.win32.common.fixed build/Makefile.win32.common
sed "s/CAIRO_HAS_FT_FONT=./CAIRO_HAS_FT_FONT=$USE_FREETYPE/" build/Makefile.win32.features > Makefile.win32.features.fixed
mv Makefile.win32.features.fixed build/Makefile.win32.features
# pass -B for switching between x86/x64
make -B -f Makefile.win32 cairo "CFG=release"
cd ..

# Package headers with DLL
OUTPUT_FOLDER=output/${CAIRO_VERSION/cairo-/cairo-windows-}
mkdir -p $OUTPUT_FOLDER/include
for file in cairo/cairo-version.h \
            cairo/src/cairo-features.h \
            cairo/src/cairo.h \
            cairo/src/cairo-deprecated.h \
            cairo/src/cairo-win32.h \
            cairo/src/cairo-script.h \
            cairo/src/cairo-ps.h \
            cairo/src/cairo-pdf.h \
            cairo/src/cairo-svg.h; do
    cp $file $OUTPUT_FOLDER/include
done
if [ $USE_FREETYPE -ne 0 ]; then
    cp cairo/src/cairo-ft.h $OUTPUT_FOLDER/include
fi
mkdir -p $OUTPUT_FOLDER/lib/$OUTPUT_PLATFORM_NAME
cp cairo/src/release/cairo.lib $OUTPUT_FOLDER/lib/$OUTPUT_PLATFORM_NAME
cp cairo/src/release/cairo.dll $OUTPUT_FOLDER/lib/$OUTPUT_PLATFORM_NAME
cp cairo/COPYING* $OUTPUT_FOLDER

trap - EXIT
echo 'Success!'
