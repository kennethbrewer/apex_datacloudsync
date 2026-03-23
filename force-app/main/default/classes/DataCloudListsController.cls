/**
 * @description       : 
 * @author            : ChangeMeIn@UserSettingsUnder.SFDoc
 * @group             : 
 * @last modified on  : 03-21-2026
 * @last modified by  : ChangeMeIn@UserSettingsUnder.SFDoc
**/
public with sharing class DataCloudListsController {

    public class ListResult {
        @AuraEnabled public List<ColumnDef> columns;
        @AuraEnabled public List<Map<String, Object>> rows;
        @AuraEnabled public String title;
    }

    public class ColumnDef {
        @AuraEnabled public String fieldName;
        @AuraEnabled public String label;
        @AuraEnabled public String type;
    }

    @AuraEnabled(cacheable=true)
    public static ListResult getListData(
        Id recordId,
        String objectApiName,
        String listName
    ) {
        if (recordId == null || String.isBlank(listName)) {
            throw new AuraHandledException('Invalid request.');
        }

        // 1️⃣ Get SNAP ID from current record
        String snapId = getSnapId(recordId, objectApiName);
        if (String.isBlank(snapId)) {
            throw new AuraHandledException('SNAP_id__c not found.');
        }

        // 2️⃣ Load Static Resource JSON
        String jsonText = loadConfig();
        Map<String, Object> config = (Map<String, Object>) JSON.deserializeUntyped(jsonText);

        if (!config.containsKey(listName)) {
            throw new AuraHandledException('Invalid Data Cloud list selection.');
        }

        Map<String, Object> listConfig =
            (Map<String, Object>) config.get(listName);

        String queryTemplate = (String) listConfig.get('query');
        Map<String, Object> fieldLabels =
            (Map<String, Object>) listConfig.get('fieldLabels');

        // 3️⃣ Replace XX with SNAP ID
        String soql = queryTemplate.replace('XX', snapId);

        // 4️⃣ Execute Data Cloud query
        List<sObject> results = Database.query(soql);

        // 5️⃣ Build response
        ListResult response = new ListResult();
        response.title = listName;
        response.columns = new List<ColumnDef>();
        response.rows = new List<Map<String, Object>>();

        for (String field : fieldLabels.keySet()) {
            ColumnDef col = new ColumnDef();
            col.fieldName = field;
            col.label = (String) fieldLabels.get(field);
            col.type = 'text';
            response.columns.add(col);
        }

        for (sObject row : results) {
            Map<String, Object> rowMap = new Map<String, Object>();
            for (String field : fieldLabels.keySet()) {
                rowMap.put(field, row.get(field));
            }
            response.rows.add(rowMap);
        }

        return response;
    }

    // 🔹 Helper: get SNAP_id__c
    private static String getSnapId(Id recordId, String objectApiName) {
        String soql = 'SELECT SNAP_id__c FROM ' + objectApiName + ' WHERE Id = :recordId';
        system.debug(soql);
        system.debug(objectApiName + ' - ' + recordId);
        system.debug('SNAP_id__c - ' + Database.query(soql));
        sObject rec = Database.query(soql);
        return (String) rec.get('SNAP_id__c');
    }

    // 🔹 Helper: load static resource
    private static String loadConfig() {
        return [
            SELECT Body
            FROM StaticResource
            WHERE Name = 'DataCloudListsConfig'
            LIMIT 1
        ].Body.toString();
    }
}