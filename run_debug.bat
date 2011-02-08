@echo off

echo Cleaning the cache...
rmdir /S /Q tmp > nul 2> nul
mkdir tmp
echo deleting old Logfiles...
del /S /Q log.*.txt > nul 2> nul
del /S /Q log.txt > nul 2> nul
echo deleting html debug pages...
del /S /Q *.htm > nul 2> nul

bin\episodescanner.exe -debug

echo now please upload your log.txt to the forum and describe your problem

pause
