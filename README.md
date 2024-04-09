# Docker Workspace for ACAL/Playlab Curriculum
A dockerized [Ubuntu 22.04](https://hub.docker.com/_/ubuntu/)

## test environment
windows 10 with wsl2 built with ubuntu 22.04

## User Guides
- If you are working on Windows systems, use the following commands in Bash-like shells such as [Git Bash](https://git-scm.com/download/win).
- Use `run` to manage the Docker image and container of this workspace.
    ```
    $ ./run

        This script will help you manage the Docker Workspace for ACAL Curriculum (version XXXXXXX).
        You can execute this script with the following options.

        start     : build and enter the workspace
        stop      : terminate the workspace
        prune     : remove the docker image
        rebuild   : remove and build a new image to apply new changes
    ```
- `./run start`
    - First execution: Build the Docker image, create a container, and enter the terminal.
    - Image exists but no running container: Create a container and enter the terminal.
    - Container is running: Enter the terminal.
- Users can put all permanent files in `~/projects` of the workspace, which is mounted to `docker-base-workspace/projects` on the host machine.
- The container won't be stopped after type `exit` in the last terminal of the workspace. Users should also use `./run stop` command on the host machine to stop and remove the container.
