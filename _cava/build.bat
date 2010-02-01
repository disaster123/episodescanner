@echo off

rmdir /S /Q episodescanner
rmdir /S /Q build
mkdir build


set progpath=%ProgramFiles%
if not "%ProgramFiles(x86)%".=="". set progpath=%ProgramFiles(x86)%

"%progpath%\Cava Packager 1.3\bin\cavapack.exe" project-local.cavapack

rmdir /S /Q build\bin

xcopy ..\*.dll build
xcopy ..\*.bat build
xcopy ..\config.sample.txt build

xcopy /kreisch ..\mtn build\mtn
rmdir /S /Q build\mtn\.svn

xcopy /kreisch ..\tmp build\tmp
rmdir /S /Q build\tmp\.svn
del /S /Q build\tmp\*

move build episodescanner

pause



