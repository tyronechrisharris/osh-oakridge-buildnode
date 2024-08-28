# OSH OAKRIDGE BUILDNODE
This repo brings in all the OSH modules and dependencies to deploy a OSH node server for ORNL. This build requires Java 11.

## Clone and build

### Clone this repository and update all submodules recursively
`git clone git@github.com:Botts-Innovative-Research/osh-oakridge-buildnode.git --recursive`

### Build a deployment of the OSH Node from the top directory in the project run:
`./gradlew build -x test`

The resulting build can be found in build/distributions/

## Deploy and Start OSH Node
Unzip the build (osh-node-ornl.zip). Run the launch script, "launch.sh" for linux/mac and "launch.bat" for windows.

You can access the OSH Node by going to **[ip-address]:8282/sensorhub/admin** if running locally go to **http://localhost:8282/sensorhub/admin**

The default credentials to access the OSH Node are admin:admin. This can be changed in the Security section of the admin page.

## Admin Control

For documentation on running the OSH Node from the admin page please refer to the Node Administration document in /documentation folder.



