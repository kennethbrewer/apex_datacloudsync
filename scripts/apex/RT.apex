/**
 * @description       : 
 * @author            : ChangeMeIn@UserSettingsUnder.SFDoc
 * @group             : 
 * @last modified on  : 03-13-2026
 * @last modified by  : ChangeMeIn@UserSettingsUnder.SFDoc
**/
           Map<Id, String> mapSnapRT = new Map<Id, String>();
            Map<String, Id> mapADIRT = new Map<String, Id>();
	
            for (RecordType_Home__dlm rec : [
                SELECT Id__c, DeveloperName__c, DataSource__c
                FROM RecordType_Home__dlm
                WHERE SobjectType__c = 'Account'
            ]) {
                if (rec.DataSource__c != 'Salesforce_Home') {
                    mapSnapRT.put(rec.Id__c, rec.DeveloperName__c);
                }
                if (rec.DataSource__c == 'Salesforce_Home') {
                    mapADIRT.put(rec.DeveloperName__c, rec.Id__c);
                }
            }
		// --------------------------------------------
		// 3. Third map<Id, Id>
		//    Key   = Id__c from first map
		//    Value = matching Id__c from second map 
		//            using DeveloperName__c as the link
		// --------------------------------------------
		Map<Id, Id> mapLookup = new Map<Id, Id>();
		
		for (Id firstKey : mapSnapRT.keySet()) {
			String devName = mapSnapRT.get(firstKey);
		
			// If DeveloperName from mapSnapRT exists as a key in mapADIRT
			if (mapADIRT.containsKey(devName)) {
				mapLookup.put(firstKey, mapADIRT.get(devName));
         
			}
		}
//system.debug(mapSnapRT);
     //   system.debug(mapLookup);
string stringlist='';
for (Id firstKey : mapSnapRT.keySet()) {
			String devName = mapSnapRT.get(firstKey);
    if(mapADIRT.containskey(devName))		
    stringlist=stringlist+devname + ', ' + firstkey +', ' +mapADIRT.get(devName) + '\n';
}
system.debug(stringlist);