@echo off

rmdir /S /Q episodescanner
rmdir /S /Q build
mkdir build

set progpath=%ProgramFiles%
if not "%ProgramFiles(x86)%".=="". set progpath=%ProgramFiles(x86)%

echo ".svn" >No.SVN.txt

copy ..\episodescanner.pl build\episodescanner
xcopy ..\libs build\libs /EXCLUDE:No.SVN.txt /A /S /I /E /Q /Y

cd build
perl2exe -I=C:\strawberry/perl/vendor/lib episodescanner
cd ..

xcopy ..\*.dll build
xcopy ..\*.bat build
xcopy ..\config.sample.txt build

xcopy ..\mtn build\mtn /EXCLUDE:No.SVN.txt /A /S /I /E /Q /Y
xcopy ..\tmp build\tmp /EXCLUDE:No.SVN.txt /A /S /I /E /Q /Y

rmdir /S /Q build\libs
del /S /Q build\tmp\*
del /S /Q build\*.pl
del /S /Q build\episodescanner
del No.SVN.txt

move build episodescanner

pause
