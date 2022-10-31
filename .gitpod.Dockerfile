# Generated with cynkrathis::use_gitpod(), do not edit.
#
# Call:
      code                           compare 
"quote(cynkrathis::use_gitpod())"                            "NULL" 

# You can find the new timestamped tags here: https://hub.docker.com/r/gitpod/workspace-base/tags
FROM gitpod/workspace-base:latest

# Install R and ccache
RUN sudo apt update
RUN sudo apt install -y \
  r-base \
  ccache \
  cmake \
   \
  # Install dependencies for devtools package
  libharfbuzz-dev libfribidi-dev
