public with sharing class OpportunityLeadAssociationService {

    // ============================================================
    // CONFIGURATION
    // ============================================================

    // "Log Activities for follow-up" (DTS Stage 1: Generate) is about recording that
    // outreach happened, not about having something still pending — a completed call
    // logged today satisfies it the same as an open follow-up task. Flip this to true
    // only if the process should instead require an OPEN Task or a FUTURE-dated Event.
    private static final Boolean REQUIRE_OPEN_OR_FUTURE_ACTIVITIES = false;

    // "Related Contacts" on the Account page is powered by AccountContactRelation
    // (not the raw Contact.AccountId field) once Contacts to Multiple Accounts is on —
    // this org uses it, so a Contact can show up under a related account without that
    // account being its primary Contact.AccountId. Flip this to false only if the org
    // ever turns that feature off and this should count direct Contacts only.
    private static final Boolean USE_ACCOUNT_CONTACT_RELATION = true;

    // ContentDocument.FileType for records created with the rich-text Note editor.
    // Anything else linked to the record is treated as a real uploaded File.
    private static final String NOTE_FILE_TYPE = 'SNOTE';

    // FeedItem.Type values that represent an actual user post. TrackedChange (and other
    // system-generated feed entries) are noise, not evidence of discovery work. Add to
    // this set if the org later wants other post types to count.
    private static final Set<String> CHATTER_USER_POST_TYPES = new Set<String>{
        'TextPost', 'ContentPost', 'LinkPost'
    };

    // "Update the Opportunity details" (DTS Stage 3: Scope & Analyze) is Completed only
    // when ALL of these fields are filled — update this constant and the checks in
    // getFilledOpportunityDetailsCount together if the required field set changes:
    //   Est_Start_Date__c   (Date)          - Start date
    //   CloseDate           (Date, std)     - Close date
    //   Description         (Textarea, std) - "Use Case" (relabeled)
    //   ProductLine__c      (Multipicklist) - Partner product
    //   Project_Type__c     (Picklist)      - Project delivery
    //   ProjectService__c   (Picklist)      - Project service
    private static final Integer OPPORTUNITY_DETAILS_TOTAL_FIELDS = 6;

    // "Confirm the SE is added to the Opportunity Team" (DTS Stage 4: Propose) counts as
    // Completed when an OpportunityTeamMember with one of these TeamMemberRole values
    // exists on the Opportunity. Update this set if the org adds another SE-equivalent role.
    private static final Set<String> SE_TEAM_MEMBER_ROLES = new Set<String>{
        'Sales Engineer', 'Lead Sales Engineer'
    };

    // "EVP review and approval" (DTS Stage 6: Approve) is Completed only when the
    // Opportunity's approval field reflects a final approved state. Other values
    // (Not Submitted, Pending, Not Approved, Recalled) are all Incomplete.
    private static final String EVP_APPROVED_VALUE = 'Approved';

    private static final Map<String, String> STAGE_TITLES = new Map<String, String>{
        'Generate' => 'Stage 1: Generate',
        'Qualify'  => 'Stage 2: Discover & Qualify',
        'Analyze'  => 'Stage 3: Scope & Analyze',
        'Propose'  => 'Stage 4: Propose',
        'Contract' => 'Stage 5: Contract (SOW)',
        'Approve'  => 'Stage 6: Approve',
        'Closed'   => 'Stage 7: Closed'
    };

    // ============================================================
    // STAGE CHECKLIST  <-- THIS IS THE PART YOU MAINTAIN BY HAND
    // ============================================================
    // Entry format: 'Exact action text|FLAG_KEY'
    // The order here is the order the actions are numbered on screen.
    // FLAG_KEY must exist in the flags map built in buildPromptText().
    //   ALWAYS_TRUE       -> always Completed (the Opportunity exists)
    //   NEVER_VERIFIABLE  -> always Incomplete (cannot be validated in this org)
    //
    // Generate and Qualify mirror what the retriever returns today.
    // Analyze/Propose/Contract/Approve/Closed are intentionally empty: fill them with
    // the exact actions from DTS_Sales_Process_Master.pdf. While a stage list is empty,
    // the prompt falls back to extracting actions from the Reference Library itself.
    private static final Map<String, List<String>> STAGE_ACTIONS = new Map<String, List<String>>{
        'Generate' => new List<String>{
            'Create a new Lead|HAS_LEAD',
            'Log Activities for follow-up|HAS_ACTIVITIES',
            'Create a new Opportunity|ALWAYS_TRUE',
            'Create a new Account|HAS_ACCOUNT',
            'Confirm the accuracy of the company website|HAS_WEBSITE',
            'Confirm the accuracy of the LinkedIn information|NEVER_VERIFIABLE',
            'Add Contacts to the Account under Related Contacts|HAS_RELATED_CONTACTS'
        },
        'Qualify' => new List<String>{
            'Create a new Opportunity in Salesforce|ALWAYS_TRUE',
            'Create a new Account when applicable|HAS_ACCOUNT',
            'Confirm the accuracy of the company website|HAS_WEBSITE',
            'Confirm the accuracy of the LinkedIn information|NEVER_VERIFIABLE',
            'Add new Contacts to the Account under Related Contacts|HAS_RELATED_CONTACTS',
            'Save pre-existing notes describing project needs to the Opportunity|HAS_PROJECT_NEEDS_NOTES',
            'Create an Event in Salesforce for the Discovery meeting|HAS_DISCOVERY_EVENT',
            'Save discovery notes to the Opportunity via Chatter or Files|HAS_DISCOVERY_NOTES_OR_FILES',
            'Submit a Resource Request for Scoping|HAS_SCOPING_RR'
        },
        'Analyze'  => new List<String>(),
        'Propose'  => new List<String>(),
        'Contract' => new List<String>(),
        'Approve'  => new List<String>(),
        'Closed'   => new List<String>()
    };

    // ============================================================
    // INVOCABLE
    // ============================================================

    public class Request {
        @InvocableVariable(label='Opportunity Id' description='The 18-character Id of the Opportunity to evaluate.' required=true)
        public String opportunityId;
    }

    public class Response {
        @InvocableVariable(label='Prompt Text' description='Prompt-ready validation checks plus a precomputed stage checklist and tally.')
        public String promptText;
    }

    // GOVERNOR LIMIT NOTE: each request runs roughly 12 SOQL queries. Prompt Builder
    // always sends a single record, so this usage is safe. If this is ever called from
    // a Flow in bulk, the guard below stops before blowing the 100-query limit.
    private static final Integer MAX_REQUESTS_PER_TRANSACTION = 7;

    @InvocableMethod(
        label='Get Opportunity Lead Association'
        description='Returns validation checks plus a precomputed, already-counted stage checklist for the DTS Sales Process assistant.'
    )
    public static List<Response> getLeadAssociation(List<Request> requests) {
        List<Response> responses = new List<Response>();
        Integer processed = 0;

        for (Request req : requests) {
            Response res = new Response();
            if (processed >= MAX_REQUESTS_PER_TRANSACTION) {
                res.promptText = 'DATA_AVAILABLE: No\n' +
                    'Reason: Too many Opportunities in one transaction; this service supports ' +
                    MAX_REQUESTS_PER_TRANSACTION + ' per call.';
            } else {
                res.promptText = buildPromptText(req.opportunityId);
                processed++;
            }
            responses.add(res);
        }
        return responses;
    }

    // ============================================================
    // PROMPT TEXT CONSTRUCTION
    // ============================================================

    private static String buildPromptText(String rawId) {
        Id oppId = safeOpportunityId(rawId);
        if (oppId == null) {
            return 'DATA_AVAILABLE: No\n' +
                   'Reason: The Opportunity Id supplied was blank or not a valid Opportunity Id.';
        }

        // Single query pulls everything needed from the record itself.
        List<Opportunity> opps = [
            SELECT Id, StageName, AccountId, Account.Website,
                   Est_Start_Date__c, CloseDate, Description,
                   ProductLine__c, Project_Type__c, ProjectService__c,
                   StageApproval__c
            FROM Opportunity
            WHERE Id = :oppId
            LIMIT 1
        ];
        if (opps.isEmpty()) {
            return 'DATA_AVAILABLE: No\n' +
                   'Reason: No Opportunity found for that Id, or the running user cannot see it.';
        }
        Opportunity opp = opps[0];

        Integer leadCount        = [SELECT COUNT() FROM Lead WHERE ConvertedOpportunityId = :oppId];
        Integer activityCount    = getLoggedActivityCount(oppId);
        Integer relatedContacts  = getRelatedContactCount(opp.AccountId);
        Integer eventCount       = getEventCount(oppId);
        ContentCounts content    = getContentCounts(oppId);
        Integer chatterPosts     = getUserChatterPostCount(oppId);
        Integer notesOrFiles     = content.fileCount + chatterPosts;
        Integer scopingRequests  = getScopingResourceRequestCount(oppId);
        Integer detailsFilled    = getFilledOpportunityDetailsCount(opp);
        Integer seTeamMembers    = getSeTeamMemberCount(oppId);
        String  evpApproval      = String.isNotBlank(opp.StageApproval__c) ? opp.StageApproval__c : 'Not Submitted';
        List<Id> projectIds      = getProjectIds(oppId);
        Integer projectResources = projectIds.isEmpty() ? 0 : getProjectResourceCount(projectIds);
        Boolean hasWebsite       = opp.AccountId != null && String.isNotBlank(opp.Account.Website);

        Map<String, Boolean> flags = new Map<String, Boolean>{
            'ALWAYS_TRUE'                  => true,
            'NEVER_VERIFIABLE'             => false,
            'HAS_ACCOUNT'                  => opp.AccountId != null,
            'HAS_LEAD'                     => leadCount > 0,
            'HAS_ACTIVITIES'               => activityCount > 0,
            'HAS_RELATED_CONTACTS'         => relatedContacts > 0,
            'HAS_WEBSITE'                  => hasWebsite,
            'HAS_PROJECT_NEEDS_NOTES'      => content.noteCount > 0,
            'HAS_DISCOVERY_EVENT'          => eventCount > 0,
            'HAS_DISCOVERY_NOTES_OR_FILES' => notesOrFiles > 0,
            'HAS_SCOPING_RR'               => scopingRequests > 0,
            'OPP_DETAILS_COMPLETE'         => detailsFilled == OPPORTUNITY_DETAILS_TOTAL_FIELDS,
            'HAS_SE_ON_TEAM'               => seTeamMembers > 0,
            'EVP_APPROVED'                 => evpApproval == EVP_APPROVED_VALUE,
            'HAS_PROJECT_RECORD'           => !projectIds.isEmpty(),
            'HAS_PROJECT_RESOURCES'        => projectResources > 0,
            'DELIVERY_RR'                  => false
        };

        String stage = (opp.StageName == null) ? '' : opp.StageName;

        List<String> lines = new List<String>();
        lines.add('DATA_AVAILABLE: Yes');
        lines.add('CURRENT_STAGE: ' + stage);
        lines.add('STAGE_TITLE: ' + (STAGE_TITLES.containsKey(stage) ? STAGE_TITLES.get(stage) : stage));
        lines.add('');
        lines.add('Has Converted Lead: ' + yesNo(leadCount > 0) + ' (' + leadCount + ' found)');
        lines.add('Logged Activities: ' + yesNo(activityCount > 0) + ' (' + activityCount + ' found)');
        lines.add('Related Contacts: ' + yesNo(relatedContacts > 0) + ' (' + relatedContacts + ' found)');
        lines.add('Discovery Event: ' + yesNo(eventCount > 0) + ' (' + eventCount + ' found)');
        lines.add('Project Needs Notes: ' + yesNo(content.noteCount > 0) + ' (' + content.noteCount + ' found)');
        lines.add('Discovery Notes or Files: ' + yesNo(notesOrFiles > 0) + ' (' + notesOrFiles + ' found)');
        lines.add('Scoping Resource Request: ' + yesNo(scopingRequests > 0) + ' (' + scopingRequests + ' found)');
        lines.add('Opportunity Details Complete: ' + yesNo(detailsFilled == OPPORTUNITY_DETAILS_TOTAL_FIELDS) +
                  ' (' + detailsFilled + ' of ' + OPPORTUNITY_DETAILS_TOTAL_FIELDS + ' filled)');
        lines.add('SE on Opportunity Team: ' + yesNo(seTeamMembers > 0) + ' (' + seTeamMembers + ' found)');
        lines.add('EVP Approval: ' + yesNo(evpApproval == EVP_APPROVED_VALUE) + ' (' + evpApproval + ')');
        lines.add('Project Record Created: ' + yesNo(!projectIds.isEmpty()) + ' (' + projectIds.size() + ' found)');
        lines.add('Project Resources Assigned: ' + yesNo(projectResources > 0) + ' (' + projectResources + ' found)');
        lines.add('Account Website Present: ' + yesNo(hasWebsite));
        lines.add('');

        List<String> actions = STAGE_ACTIONS.containsKey(stage)
            ? STAGE_ACTIONS.get(stage)
            : new List<String>();

        if (actions.isEmpty()) {
            lines.add('STAGE_TALLY_AVAILABLE: No');
        } else {
            Integer completed = 0;
            List<String> checklist = new List<String>();
            for (String entry : actions) {
                List<String> parts = entry.split('\\|');
                String label   = parts[0].trim();
                String flagKey = (parts.size() > 1) ? parts[1].trim() : 'NEVER_VERIFIABLE';
                Boolean done   = (flags.get(flagKey) == true);
                if (done) {
                    completed++;
                }
                checklist.add(label + ' || ' + (done ? 'Completed' : 'Incomplete'));
            }
            lines.add('STAGE_TALLY_AVAILABLE: Yes');
            lines.add('STAGE_COMPLETED_COUNT: ' + completed);
            lines.add('STAGE_TOTAL_COUNT: ' + actions.size());
            lines.add('STAGE_SUMMARY_LINE: ' + completed + ' of ' + actions.size() + ' actions complete.');
            lines.add('STAGE_CHECKLIST_START');
            lines.addAll(checklist);
            lines.add('STAGE_CHECKLIST_END');
        }

        return String.join(lines, '\n');
    }

    // ============================================================
    // HELPERS
    // ============================================================

    private static String yesNo(Boolean value) {
        return value ? 'Yes' : 'No';
    }

    private static Id safeOpportunityId(String value) {
        if (String.isBlank(value)) {
            return null;
        }
        try {
            Id parsed = Id.valueOf(value.trim());
            return (parsed.getSObjectType() == Opportunity.SObjectType) ? parsed : null;
        } catch (Exception e) {
            return null;
        }
    }

    private static Integer getLoggedActivityCount(Id opportunityId) {
        Integer taskCount;
        Integer eventCount;

        if (REQUIRE_OPEN_OR_FUTURE_ACTIVITIES) {
            taskCount = [
                SELECT COUNT() FROM Task
                WHERE WhatId = :opportunityId
                AND (IsClosed = false OR ActivityDate >= TODAY)
            ];
            eventCount = [
                SELECT COUNT() FROM Event
                WHERE WhatId = :opportunityId
                AND StartDateTime >= :System.now()
            ];
        } else {
            taskCount  = [SELECT COUNT() FROM Task  WHERE WhatId = :opportunityId];
            eventCount = [SELECT COUNT() FROM Event WHERE WhatId = :opportunityId];
        }
        return taskCount + eventCount;
    }

    private static Integer getRelatedContactCount(Id accountId) {
        if (accountId == null) {
            return 0;
        }
        if (USE_ACCOUNT_CONTACT_RELATION) {
            return [SELECT COUNT() FROM AccountContactRelation WHERE AccountId = :accountId];
        }
        return [SELECT COUNT() FROM Contact WHERE AccountId = :accountId];
    }

    private static Integer getEventCount(Id opportunityId) {
        return [SELECT COUNT() FROM Event WHERE WhatId = :opportunityId];
    }

    private class ContentCounts {
        Integer noteCount = 0;
        Integer fileCount = 0;
    }

    private static ContentCounts getContentCounts(Id opportunityId) {
        ContentCounts counts = new ContentCounts();
        for (ContentDocumentLink link : [
            SELECT ContentDocument.FileType
            FROM ContentDocumentLink
            WHERE LinkedEntityId = :opportunityId
        ]) {
            if (link.ContentDocument.FileType == NOTE_FILE_TYPE) {
                counts.noteCount++;
            } else {
                counts.fileCount++;
            }
        }
        return counts;
    }

    private static Integer getUserChatterPostCount(Id opportunityId) {
        return [
            SELECT COUNT() FROM FeedItem
            WHERE ParentId = :opportunityId
            AND Type IN :CHATTER_USER_POST_TYPES
        ];
    }

    private static Integer getScopingResourceRequestCount(Id opportunityId) {
        return [SELECT COUNT() FROM SFDC_Assignment__c WHERE Opportunity__c = :opportunityId];
    }

    // Takes the already-queried Opportunity to avoid an extra SOQL call.
    private static Integer getFilledOpportunityDetailsCount(Opportunity opp) {
        Integer filled = 0;
        if (opp.Est_Start_Date__c != null)             { filled++; }
        if (opp.CloseDate != null)                     { filled++; }
        if (String.isNotBlank(opp.Description))        { filled++; }
        if (String.isNotBlank(opp.ProductLine__c))     { filled++; }
        if (String.isNotBlank(opp.Project_Type__c))    { filled++; }
        if (String.isNotBlank(opp.ProjectService__c))  { filled++; }
        return filled;
    }

    private static Integer getSeTeamMemberCount(Id opportunityId) {
        return [
            SELECT COUNT() FROM OpportunityTeamMember
            WHERE OpportunityId = :opportunityId
            AND TeamMemberRole IN :SE_TEAM_MEMBER_ROLES
        ];
    }

    // SFDC_Projects__c uses two separate lookups back to Opportunity depending on how the
    // project was created (Opportunity__c and RelatedOpportunity__c) — org-wide neither one
    // alone covers all real Projects, so both are checked with OR.
    private static List<Id> getProjectIds(Id opportunityId) {
        List<Id> projectIds = new List<Id>();
        for (SFDC_Projects__c proj : [
            SELECT Id FROM SFDC_Projects__c
            WHERE Opportunity__c = :opportunityId OR RelatedOpportunity__c = :opportunityId
        ]) {
            projectIds.add(proj.Id);
        }
        return projectIds;
    }

    private static Integer getProjectResourceCount(List<Id> projectIds) {
        return [SELECT COUNT() FROM SFDC_Assignment__c WHERE Projects__c IN :projectIds];
    }
}