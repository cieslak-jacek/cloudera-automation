#!/bin/bash -e

## cluster parameters:
export CLUSTER="cdh${RANDOM}"
export AMI="ami-48f4bb31"		## SE Disabled AMI
export INSTANCE_TYPE="t2.xlarge"
export KEY_NAME="tsystems"
mkdir ${CLUSTER}

start_instance() {
	echo " -- starting instance ${CLUSTER}-${1}"
	aws ec2 run-instances \
		--image-id "${AMI}" \
		--instance-type "${INSTANCE_TYPE}" \
		--key-name "${KEY_NAME}" \
		--security-group-ids sg-fb79ce80 \
		--subnet-id subnet-036d515b \
		--block-device-mapping "DeviceName=/dev/sda1,Ebs={VolumeSize=32}" \
		--tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${CLUSTER}-${1}}]" \
		--count 1 | \
		jq -r ".Instances[].InstanceId" \
		> ${CLUSTER}/id-${1}.txt
}

start_instances() {
	echo " -- starting instance ${CLUSTER}-${1}"
	aws ec2 run-instances \
		--image-id "${AMI}" \
		--instance-type "${INSTANCE_TYPE}" \
		--key-name "${KEY_NAME}" \
		--security-group-ids sg-fb79ce80 \
		--subnet-id subnet-036d515b \
		--block-device-mapping "DeviceName=/dev/sda1,Ebs={VolumeSize=32}" \
		--tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${CLUSTER}-${1}}]" \
		--count 3 | \
		jq -r ".Instances[].InstanceId" \
		> ${CLUSTER}/id-${1}.txt
}

for INSTANCE in scm db krb gateway; do
	start_instance ${INSTANCE}
done

start_instances master
start_instances worker

cp files/inventory.template ${CLUSTER}/inventory

for INSTANCE in scm db krb gateway master worker; do
	echo " -- waiting for ${CLUSTER}-${INSTANCE}"
	aws ec2 wait instance-running --filter "Name=tag-value,Values=${CLUSTER}-${INSTANCE}"
	aws ec2 describe-instances \
		--filters "Name=tag:Name,Values=${CLUSTER}-${INSTANCE}" --region eu-west-1 --output json \
		| jq -r .Reservations[].Instances[].PrivateDnsName \
		> ${CLUSTER}/${INSTANCE}-hostnames.txt
done

for INSTANCE in scm db krb gateway; do
	IP=$(cat ${CLUSTER}/${INSTANCE}-hostnames.txt)
	echo "   ${INSTANCE} ip: ${IP}"
	sed -i s/__${INSTANCE}__/${IP}/ ${CLUSTER}/inventory
done

i=0
for IP in $(cat ${CLUSTER}/master-hostnames.txt); do
	i=$((i + 1))
	echo "   master${i} ip: ${IP}"
	sed -i "/\[master_servers\]/a ${IP}       host_template=HostTemplate-Master${i}"  ${CLUSTER}/inventory
done

for IP in $(cat ${CLUSTER}/worker-hostnames.txt); do
	echo "   worker ip: ${IP}"
	sed -i "/\[worker_servers\]/a ${IP}"  ${CLUSTER}/inventory
done

SCM=$(cat ${CLUSTER}/scm-hostnames.txt)

echo "ssh ubuntu@${SCM}"	| tee -a ${CLUSTER}/commands.txt
echo ssh -CD 8157 centos@${SCM}	| tee -a ${CLUSTER}/commands.txt
echo "http://${SCM}:7180/"      | tee -a ${CLUSTER}/commands.txt
echo "press any key...."
read -n 1 -s
ansible-playbook -i ${CLUSTER}/inventory --user=centos --private-key=~/.ssh/tsystems.pem -e krb5_kdc_type=mit -e default_realm=CDH.AWS -e krb5_kdc_admin_user=centos -e krb5_kdc_admin_passwd=password site.yml
