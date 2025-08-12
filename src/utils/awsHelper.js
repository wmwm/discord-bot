const AWS = require('aws-sdk');
AWS.config.update({ region: process.env.AWS_REGION || 'ap-southeast-2' });

// ===== EC2 =====
const ec2 = new AWS.EC2();
async function startInstance(instanceId) {
    return ec2.startInstances({ InstanceIds: [instanceId] }).promise();
}
async function stopInstance(instanceId) {
    return ec2.stopInstances({ InstanceIds: [instanceId] }).promise();
}

// ===== S3 =====
const s3 = new AWS.S3();
async function listBuckets() {
    const result = await s3.listBuckets().promise();
    return result.Buckets;
}

// ===== Lambda =====
const lambda = new AWS.Lambda();
async function invokeLambda(functionName, payload = {}) {
    const params = {
        FunctionName: functionName,
        Payload: JSON.stringify(payload)
    };
    const result = await lambda.invoke(params).promise();
    return JSON.parse(result.Payload);
}

module.exports = {
    startInstance,
    stopInstance,
    listBuckets,
    invokeLambda
};
