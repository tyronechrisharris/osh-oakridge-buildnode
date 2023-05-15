@echo off
setlocal

REM Make sure all the necessary certificates are trusted by the system.
CALL %~dp0load_trusted_certs.bat

REM Start the node
java -Xmx2g ^
    -Dlogback.configurationFile=./logback.xml ^
    -cp "lib/*" ^
    -Djava.system.class.loader="org.sensorhub.utils.NativeClassLoader" ^
    -Djavax.net.ssl.keyStore="./osh-keystore.p12" ^
    -Djavax.net.ssl.keyStorePassword="atakatak" ^
    -Djavax.net.ssl.trustStore="%~dp0trustStore.jks" ^
    -Djavax.net.ssl.trustStorePassword="changeit" ^
    org.sensorhub.impl.SensorHub config.json db

endlocal
