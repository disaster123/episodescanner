@echo off

rmdir /S /Q build
mkdir build

xcopy ..\run.bat build
xcopy ..\episodescanner.pl build
xcopy ..\config.txt build
xcopy /kreisch ..\tmp build\tmp
xcopy /kreisch ..\libs build\libs

rmdir /S /Q build\tmp\.svn
del /S /Q build\tmp\*

cd build
pp -c -C -l libs -X DBD::SQLite -X DBD::CSV -X DBD::File -X DBD::Excel -o episodescanner.exe episodescanner.pl

pause
pause
pause
pause
