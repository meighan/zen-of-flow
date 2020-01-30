({

	nav : function (recordId) {
    let navEvt = $A.get("e.force:navigateToSObject");
    navEvt.setParams({
      "recordId": recordId
    });
    navEvt.fire();
	},

	reload : function(component) {
		let helper = this;
		//get the sobjectType
		let action = component.get("c.getSharings");
		action.setParams({
			"recordId" : component.get("v.recordId")
		});

		action.setCallback(this, function(a){
			let state = a.getState();
			if (state === "SUCCESS") {
				//console.log(a);
				//lodash group by kinds
				component.set("v.shares", JSON.parse(a.getReturnValue()));
			}  else if (state === "ERROR") {
				let appEvent = $A.get("e.c:handleCallbackError");
				appEvent.setParams({
					"errors" : a.getError()
				});
				appEvent.fire();
				helper.nav(component.get("v.recordId")); //go back to the original
			}
		});
		$A.enqueueAction(action);


	},

	commonUpsert : function(component, id, level) {
		let helper = this;
		let action = component.get("c.upsertPerm");

		action.setParams({
			"UserOrGroupID" : id,
			"recordId" : component.get("v.recordId"),
			"level" : level
		});

		action.setCallback(this, function(a){
			let state = a.getState();
			if (state === "SUCCESS") {
				//console.log(a.getReturnValue());
				let toastEvent = $A.get("e.force:showToast");
				toastEvent.setParams({
					"message": "Change Successful",
					"type": "success",
				});
				toastEvent.fire();
				helper.reload(component);
			} else if (state === "ERROR") {
				//console.log(a.getError());
				let appEvent = $A.get("e.c:handleCallbackError");
				appEvent.setParams({
					"errors" : a.getError()
				});
				appEvent.fire();
			}
		});
		$A.enqueueAction(action);

	},

	translateTypes : function(userType) {
		if (userType === 'PowerCustomerSuccess') {return 'Customer + Sharing';}
		else if (userType === 'PowerPartner') {return 'Partner';}
		else if (userType === 'CustomerSuccess') {return 'Customer';}
		else if (userType === 'CsnOnly') {return 'Chatter';}
		else if (userType === 'CSPLitePortal') {return 'High Volume Customer';}
		else {return userType;}
	},

	getStuff : function(component) {
		let sobj = component.get("v.sObjectName");
		//console.log(component.get("v.recordId"));

		//console.log(sobj);

		let output = {};

		//defaults
		output.lookupField = "ParentId";
		output.accessLevelField = "AccessLevel";

		//object
		if (sobj.includes("__c")){
			output.objectName = sobj.replace("__c","__Share");
		} else {
			output.objectName = sobj+"Share";
		}

		//overrides for most "older" standard objects
		if (sobj==="Account" || sobj==="Asset" || sobj==="Campaign" || sobj ==="Case" || sobj==="Contact" || sobj==="Lead" || sobj==="Opportunity" || sobj==="User" ){
			output.lookupField = sobj + "Id";
			output.accessLevelField = sobj + "AccessLevel";
		}

		//console.log(output);
		return output;
	}


})