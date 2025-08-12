const aws = require('./src/utils/awsHelper');

(async () => {
    try {
        // Test S3 connection
        const buckets = await aws.listBuckets();
        console.log("S3 Buckets:", buckets);

        // Uncomment below to test EC2 start (replace with your instance id)
        // const result = await aws.startInstance('i-xxxxxxxxxxxxxxx');
        // console.log("Start EC2 result:", result);

    } catch (err) {
        console.error("AWS Test Failed:", err);
    }
})();
