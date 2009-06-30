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
ren episodescanner.pl episodescanner
REM -f Crypto -F Crypto -M Filter::Crypto::Decrypt
REM -f Squish -F Squish -M PAR::Filter::Squish
start "pp" /WAIT pp -C -c -f PodStrip -F PodStrip -M PAR::Filter::PodStrip -f Squish -F Squish -M PAR::Filter::Squish -X config.txt -X DBD::SQLite -X DBD::CSV -X DBD::File -X DBD::Excel -o episodescanner.exe episodescanner
del episodescanner
rmdir /S /Q libs
cd ..

pause
