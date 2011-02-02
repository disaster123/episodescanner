@echo off

rmdir /S /Q episodescanner
rmdir /S /Q build
mkdir build

set progpath=%ProgramFiles%
if not "%ProgramFiles(x86)%".=="". set progpath=%ProgramFiles(x86)%

echo ".svn" >No.SVN.txt

xcopy ..\episodescanner.pl build
xcopy ..\libs build\libs /EXCLUDE:No.SVN.txt /A /S /I /E /Q /Y

cd build
REM -c is not possible with Crypto
REM -C  DO clean Cache libs and files
cmd /C pp -v -I libs -f PodStrip -F PodStrip -M PAR::Filter::PodStrip -f Crypto -F Crypto -M Filter::Crypto::Decrypt -X Carp -X DBD::SQLite -X DBD::CSV -X DBD::File -X DBD::Excel -o episodescanner.exe episodescanner.pl
cd ..

xcopy ..\*.dll build
xcopy ..\*.bat build
xcopy ..\config.sample.txt build

xcopy ..\mtn build\mtn /EXCLUDE:No.SVN.txt /A /S /I /E /Q /Y
xcopy ..\tmp build\tmp /EXCLUDE:No.SVN.txt /A /S /I /E /Q /Y

rmdir /S /Q build\libs
del /S /Q build\tmp\*
del /S /Q build\*.pl
del No.SVN.txt

move build episodescanner

pause
