#------ functions for use from buildshims -------

# Print a message and terminate with nonzero status.
bs_abort() {
    echo fatal error: $*
    exit 1
}

# Echo a short code for the operating system / version.
# e.g. osx107, ubu1204, or cygwin
# FIXME: should probably be win7 or win8 rather than cygwin

bs_detect_os() {
    # Detect OS
    case "`uname -s`" in
    Linux)
        case "`lsb_release -ds`" in
        "Ubuntu 10.04"*) echo ubu1004;;
        "Ubuntu 12.04"*) echo ubu1204;;
        *) bs_abort "unrecognized linux";;
        esac
        ;;
    Darwin)
        case `sw_vers -productVersion` in
        10.7.*) echo osx107;;
        *) bs_abort "unrecognized mac";;
        esac
        ;;
    CYGWIN*WOW64) echo cygwin;;
    CYGWIN*)      echo cygwin;;
    *) bs_abort "unrecognized os";;
    esac
}

# Echo the number of CPU cores
bs_detect_ncores() {
    case $_os in
    ubu*)
        grep -c processor /proc/cpuinfo || echo 1
        ;;
    osx*)
        system_profiler -detailLevel full SPHardwareDataType | awk '/Total Number .f Cores/ {print $5};'
        ;;
    cygwin)
        echo $NUMBER_OF_PROCESSORS
        ;;
    esac
}

# Echo the version number of this project as given by configure.ac
bs_get_version_configure_ac() {
    # Only look at top few lines
    # Remove comments
    # Reformat so there is exactly one line per macro call
    # Grab just the call to AC_INIT
    # delete everything up to and including the open paren
    # print out the second [parameter],
    # and remove brackets, commas, and spaces

    FILE=configure.ac
    test -f $FILE || FILE=configure.in
    test -f $FILE || bs_abort "Could not find configure.ac or configure.in"
    WORD=`head -n 20 $FILE |
        sed 's/dnl.*//' |
        tr '\012)' ' \012' |
        grep AC_INIT |
        sed 's/.*(//' |
        sed 's/\[[^]]*\]//' |
        sed 's/\].*//' |
        tr -d '][, '`
    case "$WORD" in
    ""|" ") bs_abort "bs_get_version_configure_ac failed to parse version from AC_INIT in $FILE";;
    *) echo $WORD;;
    esac
}

# Echo the version number of this project as given by CMakeLists.txt
bs_get_version_cmake() {
    # Only look at top few lines
    # Remove comments
    # Grab just the call to set(VERSION ...)
    # delete everything up to and including VERSION
    # and remove parens and spaces

    head -n 20 CMakeLists.txt |
        sed 's/#.*//' |
        tr '\012)' ' \012' |
        grep 'set(VERSION' |
        sed 's/.*VERSION//' |
        tr -d '") '
}

# Echo the version number of this product as given by debian/changelog,
# (with the change number stripped off if present).
bs_get_version_debian_changelog() {
    test -f debian/changelog || abort "Couldn't open debian/changelog"
    # First line should be something like
    # foobar (5.6.7) unstable; urgency=low
    # or
    # liblbfgs (1.10-2) unstable; urgency=low
    head -n 1 debian/changelog | grep $pkgname | sed 's/.*(//;s/).*//;s/-[0-9]*$//'
}

# Echo the version number of this product as given by git
# This works for projects that name branches like kernel.org, Wine, or Node do
bs_get_version_git() {
    # git describe --long's output looks like
    # name-COUNT-CHECKSUM
    # Strip off the -CHECKSUM, then the -COUNT, then (hail mary) strip off any non-numeric prefix.
    d1=`git describe --long`
    d2=`echo $d1 | sed 's/-[a-z0-9][a-z0-9][a-z0-9][a-z0-9][a-z0-9][a-z0-9][a-z0-9][a-z0-9]$//'`
    d3=`echo $d2 | sed 's/-[0-9]*$//'`
    d4=`echo $d3 | sed 's/^[^0-9]*//'`
    case "$d4" in
    "") bs_abort "can't parse version number from git describe --long's output $d1";;
    esac
    echo $d4
}

# Echo the change number since the start of this branch as given by git
bs_get_git_changenum() {
    # git describe --long's output looks like
    # name-COUNT-CHECKSUM
    # First strip off the checksum field, then the name.
    d1=`git describe --long`
    d2=`echo $d1 | sed 's/-[a-z0-9][a-z0-9][a-z0-9][a-z0-9][a-z0-9][a-z0-9][a-z0-9][a-z0-9]$//'`
    d3=`echo $d1 | sed 's/^.*-//'`
    case "$d3" in
    "") bs_abort "can't parse change number from git describe --long's output $d1";;
    esac
    echo $d3
}

# Apply workarounds commonly needed on non-linux platforms
bs_platform_workarounds() {
    case $_os in
    cygwin)
        # Get access to batch files next to the main script
        WSRC=`cygpath -w $SRC`
        # Work around http://www.cmake.org/Bug/print_bug_page.php?bug_id=13131
        unset TMP TEMP tmp temp
        export TMP=c:\\windows\\temp
        export TEMP=c:\\windows\\temp

        PATH=/bin:$PATH  # find Cygwin's find.exe rather than Windows'
        ;;
    esac
}

# Set environment variables CC, CXX, and on Mac OS X, OBJC
# to point to the standard compiler.
# Use ccache if it's present and its cache directory exists.
bs_set_CC() {
    case $_os in
    cygwin)
        # On Windows, we're building with Visual C++, which doesn't support ccache.
        unset CCACHE_DIR
        ;;
    ubu*)
        # If ccache is configured, use it.
        if ccache -V && test -d "$CCACHE_DIR"
        then
            CC="ccache gcc"
            CXX="ccache g++"
        else
            CC=gcc
            CXX=g++
        fi
        export CC
        export CXX
        ;;
    osx*)
        # If ccache is configured, use it.
        if ccache -V && test -d "$CCACHE_DIR"
        then
            CC="ccache gcc"    # or ccache clang
            CXX="ccache g++"   # or ccache clang++
            OBJC="ccache gcc"  # or ccache clang
        else
            CC=gcc
            CXX=g++
            OBJC=gcc
        fi
        export CC
        export CXX
        export OBJC
        ;;
    esac
}
