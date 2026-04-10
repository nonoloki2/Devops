SELECT
    sys.Name0 AS DeviceName,
    sys.User_Name0 AS UserName,

    CASE
        WHEN app.EnforcementState = 1000 THEN 'Success (1000)'
        WHEN app.EnforcementState IN (1001,1002,1003,1004,1005) THEN CONCAT('In Progress (', app.EnforcementState, ')')
        WHEN app.EnforcementState IN (2000,2001,2002,2003,2004,2005) THEN CONCAT('Error (', app.EnforcementState, ')')
        WHEN app.EnforcementState IN (4000,4001,4002,4003,4004,4005) THEN CONCAT('Unknown (', app.EnforcementState, ')')
        WHEN app.EnforcementState IN (5000,5001,5002,5003,5004,5005) THEN CONCAT('In Progress (', app.EnforcementState, ')')
        WHEN app.ResourceID IS NULL THEN 'Unknown (No State)'
        ELSE CONCAT('Other (', app.EnforcementState, ')')
    END AS Status,
    app.EnforcementState
FROM v_FullCollectionMembership fcm
INNER JOIN v_R_System sys
    ON sys.ResourceID = fcm.ResourceID
LEFT JOIN vAppDeploymentResultsPerClient app
    ON app.ResourceID = fcm.ResourceID
    AND app.AssignmentID = 16792084
WHERE fcm.CollectionID = 'CT10260E'
ORDER BY sys.Name0