@echo off

rmdir /S /Q episodescanner
rmdir /S /Q build
mkdir build

"%PROGRAMFILES%\Cava Packager 1.3\bin\cavapack.exe" project.cavapack

rmdir /S /Q build\bin

xcopy ..\run.bat build
xcopy ..\config.txt build
xcopy /kreisch ..\tmp build\tmp

rmdir /S /Q build\tmp\.svn
del /S /Q build\tmp\*

move build episodescanner

pause



