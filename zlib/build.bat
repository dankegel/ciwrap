mkdir msvcbuild
cd msvcbuild
cmake -G "Visual Studio 10" ..

call settings.bat
vcexpress zlib.sln /build "Release|Win32"

vcexpress zlib.sln /build "Release|Win32" /project RUN_TESTS
type msvcbuild\Testing\Temporary\LastTest.log
