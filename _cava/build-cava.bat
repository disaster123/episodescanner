@echo off

rmdir /S /Q episodescanner
rmdir /S /Q installer
rmdir /S /Q release
rmdir /S /Q project\testbuild

set progpath=%ProgramFiles%
if not "%ProgramFiles(x86)%".=="". set progpath=%ProgramFiles(x86)%

echo ".svn" >No.SVN.txt

"%progpath%\Cava Packager\bin\cavaconsole" --scan --build --project="%CD%\cava20.cpkgproj"

xcopy ..\*.dll release
xcopy ..\*.bat release
xcopy ..\config.sample.txt release

xcopy ..\mtn release\mtn /EXCLUDE:No.SVN.txt /A /S /I /E /Q /Y
xcopy ..\tmp release\tmp /EXCLUDE:No.SVN.txt /A /S /I /E /Q /Y
del /Q release\tmp\*

del No.SVN.txt

move release episodescanner

rmdir /S /Q installer
rmdir /S /Q project\testbuild

pause