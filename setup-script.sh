#!/usr/bin/env bash

export PATH=$PATH:/opt/bitnami/java/bin

echo "Installing required system packages"
apt-get install -y -qq zip

function install_docker_gcloud() {
  apt-get update
  apt-get clean
  # Install Docker
  echo "Installing Docker"
  curl -sSL https://get.docker.com | sudo sh
  # Start docker
  echo "Start Docker"
  sudo /etc/init.d/docker restart
  
  echo "update gcloud components"
  gcloud components update preview app -q
  echo "finished gcloud components update"
}

install_docker_gcloud &


MASTER="http://$(hostname -i | sed 's/ /\n/g' | grep -v 127.0.0.1 | head -n 1)/jenkins"
SLAVE_JAR=slave.jar
RETRY=1200
SLEEP=5 # seconds
SUCCESS=""
for TRY in $(seq 1 $RETRY); do
  # Attempt to download the slave.jar file. Note that the master host may not
  # be up, so we need to ignore any connection error.
  curl -O $MASTER/jnlpJars/slave.jar || true

  # Verify that a jar file, not the "Please wait for Jenkins to be up" page
  # was downloaded. This should also cover the case that no file was downloaded.
  if zip -T $SLAVE_JAR ; then
    SUCCESS=true
    break;
  fi
  echo "Jenkins may not be up and running yet, waiting..." 1>&2
  sleep $SLEEP
done

# Download CLI
wget $MASTER/jnlpJars/jenkins-cli.jar
META_URL=http://metadata/computeMetadata/v1beta1/instance/attributes
PASSWORD=$(curl $META_URL/bitnami-base-password)
USER=$(curl $META_URL/bitnami-default-user)

echo "Connecting to Jenkins with user=$USER,password=$PASSWORD"

# Avoid doing "-s $MASTER" every time running jenkins-cli.jar
export JENKINS_URL=$MASTER
java -jar jenkins-cli.jar login --username $USER --password $PASSWORD

# Update System message to indicate changes in progress
java -jar jenkins-cli.jar groovy = <<EOF
  import jenkins.model.Jenkins
  Jenkins.instance.markupFormatter = hudson.markup.RawHtmlMarkupFormatter.INSTANCE
  Jenkins.instance.systemMessage = """
<head>
<style>
  h2   {color:red}
</style>
</head>
<h2> Your Jenkins is still being setup.  Please wait patiently. </h2>
  """
EOF

java -jar jenkins-cli.jar groovy = <<EOF
  import jenkins.model.Jenkins
  import hudson.plugins.git.GitTool

  // Force update in Update Center without requiring first access
  // from a browser.
  Jenkins.instance.updateCenter.updateAllSites()

  // The default Git installation ins't working on our slaves.
  // We'll replace with the default that expects "git" to be on $PATH.
  gitDesc = Jenkins.instance.getDescriptor(GitTool.class)
  gitTools = [ new GitTool(GitTool.DEFAULT, "git", []) ] as GitTool[]
  gitDesc.setInstallations(gitTools)
  gitDesc.save()
EOF

for PLUGIN in gradle oauth-credentials google-oauth-plugin \
              google-metadata-plugin google-storage-plugin google-source-plugin; do
  java -jar jenkins-cli.jar install-plugin $PLUGIN -deploy
done

# Restart Jenkins now,  Bitnami image requires Tomcat to also be restarted.
service bitnami restart

echo "Wait for docker & gcloud installation to be complete"
wait

echo "docker & gcloud installation to be completed"

for SLAVE_NAME in cloud-dev-{python,java,php,go}; do
  IMAGE_NAME="container.cloud.google.com/_b_dev_containers/$SLAVE_NAME:prod"
  gcloud docker pull $IMAGE_NAME

  # Add a slave
  java -jar jenkins-cli.jar create-node $SLAVE_NAME <<CONFIG_XML_SLAVE
    <slave>
      <name>$SLAVE_NAME</name>
      <description></description>
      <remoteFS>/var/jenkins/</remoteFS>
      <numExecutors>1</numExecutors>
      <mode>NORMAL</mode>
      <retentionStrategy class="hudson.slaves.RetentionStrategy\$Always"/>
      <!-- Give this node the label slave (because it is one)
           and the more specific label of its SDC -->
      <launcher class="hudson.slaves.JNLPLauncher"/>
      <label>$SLAVE_NAME</label>
      <nodeProperties/>
    </slave>
CONFIG_XML_SLAVE

  # Bring it online
  java -jar jenkins-cli.jar online-node $SLAVE_NAME

  mkdir -p /container-tmp/$SLAVE_NAME

  cat > slave-startup-$SLAVE_NAME.sh <<EOF
curl -O $MASTER/jnlpJars/$SLAVE_JAR

# Download the slave-agent.jnlp file. At this point Jenkins is already up,
# therefore we won't see the "Please wait for Jenkins..." page any more.
export JNLP_FILE=slave-agent.jnlp
curl --retry $RETRY --retry-delay $SLEEP \
  -O $MASTER/computer/$SLAVE_NAME/\$JNLP_FILE \
  --user $USER:$PASSWORD

# The slaves stay up until the host VM is torn down,
# so ensure things stay up.  This allows us to reconnect
# slaves if the master has a temporary issue or is told
# by the user to restart.
while true
do
  java -jar $SLAVE_JAR -jnlpUrl file:///\$JNLP_FILE -jnlpCredentials $USER:$PASSWORD
  sleep 10
done
EOF


  nohup docker run -i --privileged \
    -v /container-tmp/docker/$SLAVE_NAME:/var/lib/docker \
    -v /container-tmp/slave-home/$SLAVE_NAME:/var/jenkins \
    $IMAGE_NAME /bin/bash < slave-startup-$SLAVE_NAME.sh &

done

# Add the robot account cred
PROJECT=$(curl http://metadata/computeMetadata/v1beta1/project/project-id)

java -jar jenkins-cli.jar groovy = <<EOF
  import com.cloudbees.plugins.credentials.SystemCredentialsProvider
  import com.google.jenkins.plugins.credentials.oauth.GoogleRobotMetadataCredentials

  robotCred = new GoogleRobotMetadataCredentials("$PROJECT", null)
  SystemCredentialsProvider.instance.credentials.add(robotCred) 
EOF

# Update System message to indicate setup completion.
java -jar jenkins-cli.jar groovy = <<EOF
  import jenkins.model.Jenkins
  Jenkins.instance.systemMessage = ""
EOF

java -jar jenkins-cli.jar logout


