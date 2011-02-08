#@echo off

rmdir /S /Q episodescanner
rmdir /S /Q build
mkdir build

set progpath=%ProgramFiles%
if not "%ProgramFiles(x86)%".=="". set progpath=%ProgramFiles(x86)%

echo ".svn" >No.SVN.txt

copy ..\episodescanner.pl build\episodescanner
xcopy ..\libs build\libs /EXCLUDE:No.SVN.txt /A /S /I /E /Q /Y

cd build
"%progpath%\p2x\perl2exe" -tiny -I=C:\strawberry/perl/vendor/lib episodescanner
mkdir lib
move *.dll lib
REM copy C:\strawberry\c\bin\libgcc_s_sjlj-1.dll lib
REM copy C:\strawberry\c\bin\libmysql_.dll lib
REM copy C:\strawberry\c\bin\libxml2-2_.dll lib
REM copy C:\strawberry\c\bin\libiconv-2_.dll lib
REM copy C:\strawberry\c\bin\libz_.dll lib
move lib\p2x*.dll .
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
