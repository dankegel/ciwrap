set
pushd btmp
call "c:\Program Files (x86)\Microsoft Visual Studio 10.0\Common7\Tools\vsvars32.bat"
vcexpress zlib.sln /build "Release|Win32" /project RUN_TESTS
popd
