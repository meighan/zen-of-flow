global with sharing class LightningSharing {

	global class SharingPermsException extends Exception{}

	@AuraEnabled
	public static string sayMyName(id recordId){
		string nameField;

		Schema.SObjectType token = recordId.getSObjectType();
		for (Schema.SObjectField dfr:token.getDescribe().fields.getMap().values()){
			if (dfr.getDescribe().isNameField()){
				nameField = dfr.getDescribe().getName();
			}
		}
		string query = 'select ' + nameField + ' from ' + recordId.getSObjectType() + ' where id = \'' + recordId + '\'';
		system.debug(query);
		recordStuff rs = new recordStuff();
		rs.recordName = string.valueOf(Database.query(query)[0].get(nameField));
		rs.objectType = string.valueOf(recordId.getSObjectType().getDescribe().getLabel());

		return JSON.serialize(rs);

	}

	class recordStuff {
		string recordName {get;set;}
		string objectType {get;set;}
	}

	@AuraEnabled
	global static boolean canIEditPerms(id recordId){
		try {
			//if you're the owner, you're cool
			string query = 'select ownerId from ' + objectTypeFromId(recordId) + ' where id = \'' + String.escapeSingleQuotes(string.valueOf(recordId)) + '\'';
			sobject o = database.query(query);
			if (o.get('ownerId') == userInfo.getUserID()){
				system.debug('edit allowed because owner');
				return true;
			}

			//if you have modify allData, you're also cool
			list<PermissionSetAssignment> modifiers = [SELECT AssigneeId FROM PermissionSetAssignment WHERE PermissionSet.PermissionsModifyAllData = true];
			for (PermissionSetAssignment psa:modifiers){
				if (psa.AssigneeId == userInfo.getUserID()){
					system.debug('edit allowed because admin');
					return true;
				}
			}
		} catch (system.queryException e){
			//it's possible you can't even see that record and the queries are null!
			return false;
		}
		return false;
	}

	@AuraEnabled
	global static void deletePerm(id UserOrGroupID, id recordId){
		//access check
		Schema.DescribeSObjectResult describe = getSharingDescribe(recordId);

		//can I delete the sharing objects?
		if (!describe.isDeletable() || !describe.isAccessible()){
			throw new AuraHandledException('You don\'t have the proper permissions for ths action');
		}

		string query = buildQuery(recordId);
		query = query + ' and UserOrGroupID =\''+String.escapeSingleQuotes(UserOrGroupID)+'\'';
		system.debug(query);

		list<sobject> existing = database.query(query);
		system.debug(existing);
		delete existing;

	}

	@AuraEnabled
	global static string upsertPerm (id UserOrGroupID, id recordId, string level){

		Schema.DescribeSObjectResult describe = getSharingDescribe(recordId);
		level = String.escapeSingleQuotes(level);

		if (!canIEditPerms(recordId)){
			throw new AuraHandledException('Only the record owner or administrators can modify permissions');
		}
		system.debug('doing perm upsert');

		// special handling for role => groups
		if (UserOrGroupID.getSobjectType()==Schema.UserRole.SObjectType){
			//it's a role...find the matching group?
			list<group> matchingGroups = [select id, name, type from group where RelatedId =: UserOrGroupID and type = 'Role'];
			if (matchingGroups.size()>1){
				throw new AuraHandledException('There are multiple groups for that role');
			}
			UserOrGroupID = matchingGroups[0].Id;
		}


		string query = buildQuery(recordId);
		query = query + ' and UserOrGroupID =\''+String.escapeSingleQuotes(string.valueOf(UserOrGroupID))+'\'';
		system.debug(query);

		list<sobject> existing = database.query(query);
		string sobj = objectTypeFromId(recordId);

		if (existing.size() > 0){
			system.debug('already existing. will update');
			//can I update this thing?

			if (!describe.isUpdateable() ||
				!describe.fields.getMap().get(getAccessLevelField(sobj)).getDescribe().isUpdateable()
				){
				throw new AuraHandledException('Only the record owner or administrators can modify permissions');
			}

			existing[0].put(getAccessLevelField(sobj), level);
			update existing;
			return JSON.serialize(existing);
			} else {
				system.debug('not already existing. will create');
				//are we even allowed to insert this?  for these specific fields that we'll set?
				if (!describe.isCreateable() ||
						!describe.fields.getMap().get(getAccessLevelField(sobj)).getDescribe().isCreateable() ||
						!describe.fields.getMap().get(getLookupField(sobj)).getDescribe().isCreateable() ||
						!describe.fields.getMap().get('UserOrGroupId').getDescribe().isCreateable()
					 ){
					throw new AuraHandledException('Only the record owner or administrators can create new permissions');
				}
				//create a new SObject dynamically and insert
				Schema.SObjectType newObj = Schema.getGlobalDescribe().get(getSharingTableName(sobj));
				sobject share = newObj.newSObject();

				share.put(getAccessLevelField(sobj), level);
				share.put(getLookupField(sobj), recordId);
				share.put('UserOrGroupId', String.escapeSingleQuotes(string.valueOf(UserOrGroupID)));

				if (objectTypeFromId(recordId)=='Account'){
					//share.put('ContactAccessLevel', level);
					share.put('CaseAccessLevel', level);
					share.put('OpportunityAccessLevel', level);
				}

				insert share;
				return JSON.serialize(share);
			}
		return null;
	}

	@AuraEnabled
	global static string doSOSL(String searchString, string objectType){
		//Bobby Tables says always sanitize your inputs.
		searchString = String.escapeSingleQuotes(searchString);
		objectType = String.escapeSingleQuotes(objectType);

		//check CRUD/FLS
		//what object is this?
		Schema.DescribeSObjectResult describe = Schema.getGlobalDescribe().get(objectType).getDescribe();
		//can I query?
		if (!describe.isQueryable() || !describe.isAccessible()){
			throw new AuraHandledException('You don\'t have the proper permissions for ths action');
		}

		Map<String, Schema.SObjectField> fieldMap = describe.fields.getMap();
		for (Schema.SObjectField field:fieldMap.values()){
			if (field.getDescribe().isNameField()){
				if (!field.getDescribe().isAccessible()){
					throw new AuraHandledException('You don\'t have the proper permissions for ths action');
				}
			}
		}

		// limit rows returned for performance reasons
		string sosl = 'FIND \'*' + searchString + '*\' IN NAME FIELDS RETURNING ' + getReturning(objectType) + ' limit 500';
		list<list<sobject>> results = search.query(sosl);

		list<sobject> output = new list<sobject>();
		for (list<sobject> result:results){
			output.addAll(result);
		}

		return JSON.serialize(output);
	}

	@TestVisible
	private static string getReturning (string objectType){
		//assert that we can use these fields as the current user
		if (!User.Id.getDescribe().isAccessible() ||
			  !User.Name.getDescribe().isAccessible() ||
			  !User.UserType.getDescribe().isAccessible() ||
			  !Group.Id.getDescribe().isAccessible() ||
			  !Group.Name.getDescribe().isAccessible()
			){
			throw new AuraHandledException('You do not have the required permissions for this action');
		}


		//filter out user types that don't have sharing!
		if (objectType == 'User'){
			return 'User(Id, Name, UserType WHERE UserType in (\'Standard\', \'PowerCustomerSuccess\', \'PowerPartner\'))';
		}
		if (objectType == 'Group'){
			return objectType + '(Id, Name, Type)';
		} else {
			return objectType + '(Id, Name)';
		}
	}



@AuraEnabled
global static string objectTypeFromId(id recordId){
	Schema.SObjectType token = recordId.getSObjectType();
	Schema.DescribeSObjectResult dr = token.getDescribe();
	return dr.getName();
}

@AuraEnabled
global static string getSharings(id recordId){
	if (!canIEditPerms(recordId)){
		throw new AuraHandledException('Only the record owner or administrators can access permissions');
	}
	list<sobject> results = database.query(buildQuery(recordId));
	list<sharingHolder> output = new list<sharingHolder>();

	set<id> groupAndUserIDs = new set<id>();
	set<id> RoleIds = new set<id>();

	for (sobject so:results){
		sharingHolder sh = new sharingHolder();
		sh.RowCause = string.valueOf(so.get('RowCause'));
		sh.AccessLevel = string.valueOf(so.get(getAccessLevelField(objectTypeFromId(recordId))));
		sh.UserOrGroupID = string.valueOf(so.get('UserOrGroupID'));
		groupAndUserIDs.add(sh.UserOrGroupID);
		output.add(sh);
	}

	if (!User.Id.getDescribe().isAccessible() ||
			  !User.Name.getDescribe().isAccessible() ||
			  !User.UserType.getDescribe().isAccessible() ||
			  !Group.Id.getDescribe().isAccessible() ||
			  !Group.Name.getDescribe().isAccessible() ||
			  !Group.Type.getDescribe().isAccessible()
			){
			throw new AuraHandledException('You do not have the required permissions for this action');
		}
	map<id, user> UserMap = new map<id, user>([select Name, UserType from User where id in: groupAndUserIDs]);
	map<id, group> GroupMap = new map<id, group>([select Name, Type, RelatedId from Group where id in: groupAndUserIDs]);
	for (group g:GroupMap.values()){
		if (g.RelatedId != null){
			RoleIds.add(g.RelatedId);
		}
	}
	map<id, UserRole> RoleMap = new map<id, userrole>([select Name from UserRole where id in: RoleIDs]);

	for (sharingHolder sh:output){
		if (UserMap.get(sh.UserOrGroupID)!=null){
			//it's a user
			sh.UserOrGroupType = 'User';
			sh.UserOrGroupName = UserMap.get(sh.UserOrGroupID).Name;
			sh.SubType = huh(UserMap.get(sh.UserOrGroupID).UserType);
			} else if (GroupMap.get(sh.UserOrGroupID)!=null){
				sh.UserOrGroupType = 'Group';
				sh.SubType = GroupMap.get(sh.UserOrGroupID).Type;
				sh.UserOrGroupName = GroupMap.get(sh.UserOrGroupID).Name;
				//special handling for roles
				if (sh.SubType.contains('Role')){
					sh.UserOrGroupName = RoleMap.get(GroupMap.get(sh.UserOrGroupID).RelatedId).Name;
				}
			}
		}

		return JSON.serialize(output);
	}

	@TestVisible private static string buildQuery(id recordId){
		string sobj = objectTypeFromId(recordId);

		schema.DescribeSObjectResult describe = getSharingDescribe (recordId);

		if (!describe.isAccessible() ||
			  !describe.fields.getMap().get('Id').getDescribe().isAccessible() ||
			  !describe.fields.getMap().get('RowCause').getDescribe().isAccessible() ||
			  !describe.fields.getMap().get('UserOrGroupId').getDescribe().isAccessible() ||
			  !describe.fields.getMap().get(getAccessLevelField(sobj)).getDescribe().isAccessible() ||
			  !describe.fields.getMap().get(getLookupField(sobj)).getDescribe().isAccessible()
			  ){
			throw new AuraHandledException('You don\'t have the required permissions for this action');
		}

		string query = 'select Id, RowCause, UserOrGroupId, ' +getAccessLevelField(sobj)+ ' from ' +getSharingTableName(sobj)+ ' where ' + getLookupField(sobj)+ ' = \'' + String.escapeSingleQuotes(string.valueOf(recordId)) + '\'';
		system.debug(query);
		return query;
	}

	@TestVisible private static string huh(string userType){
		if (userType == 'PowerCustomerSuccess') {return 'Customer Plus (with Sharing)';}
		else if (userType == 'PowerPartner') {return 'Partner';}
		else if (userType == 'CustomerSuccess') {return 'Customer';}
		else if (userType == 'CsnOnly') {return 'Chatter';}
		else if (userType == 'CSPLitePortal') {return 'High Volume Customer';}
		else {return userType;}
	}

	global class sharingHolder {
		global string UserOrGroupName {get;set;}
		global string SubType {get;set;}
		global string UserOrGroupType {get;set;}
		global string UserOrGroupID {get;set;}
		global string AccessLevel {get;set;}
		global string RowCause {get;set;}
	}

	private static boolean isStandard (string sobj){
		if (sobj=='Account' || sobj=='Asset' || sobj=='Campaign' || sobj =='Case' || sobj=='Contact' || sobj=='Lead' || sobj=='Opportunity' || sobj=='User' ){
			return true;
		}
		return false;
	}

	@TestVisible
	private static string getLookupField (string sobj){
		if (isStandard(sobj)){
			return sobj + 'Id';
		} else {
			return 'ParentId';
		}
	}

	@TestVisible
	private static string getAccessLevelField (string sobj){
		system.debug('accesslevelField received sobject type :' + sobj);
		if (isStandard(sobj)){
			system.debug('is a special object');
			return sobj + 'AccessLevel';
		} else {
			system.debug('is not a special object');
			return 'AccessLevel';
		}
	}

	@TestVisible
	private static string getSharingTableName (string sobj){
		if (sobj.contains('__c')){
			return sobj.replace('__c','__Share');
		} else {
			return sobj+'Share';
		}
	}

	@TestVisible
	private static schema.DescribeSObjectResult getSharingDescribe (id recordId){
		try{
			string sharingName = getSharingTableName(objectTypeFromId(recordId));
			return Schema.getGlobalDescribe().get(sharingName).getDescribe();
		} catch (exception e){
			//probably means they don't have sharing turned on for this object
			throw new AuraHandledException('There is no sharing table for that object.  Are you SURE you changed the sharing setting to PRIVATE or READ ? ');
		}
	}

}