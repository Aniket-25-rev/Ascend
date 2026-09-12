@isTest(SeeAllData=true)
private class HaasPricingTriggerHandlerTest {

    // ── Constants (mirrors private values in handler) ────────────────────────
    private static final String HAAS_HARDWARE_SKU       = '001-INFR-ASC-HAAS-HAAS-001';
    private static final String HAAS_IMPLEMENTATION_SKU = '001-INFR-SVC-HAAS-IMPL-001';

    // ── Data helpers ─────────────────────────────────────────────────────────

    /**
     * In test context, the standard pricebook is invisible to SOQL queries.
     * Test.getStandardPricebookId() is the only reliable way to retrieve it.
     */
    private static Id stdPricebookId() {
        return Test.getStandardPricebookId();
    }

    /**
     * Returns the existing Product2 with this SKU if one already exists in the
     * org (common in Revenue Cloud orgs where catalog products are pre-seeded),
     * otherwise inserts a new one. Avoids DUPLICATE_VALUE without needing an
     * external-ID upsert key.
     */
    private static Product2 upsertProduct(String sku) {
        List<Product2> existing = [
            SELECT Id FROM Product2 WHERE StockKeepingUnit = :sku LIMIT 1
        ];
        if (!existing.isEmpty()) return existing[0];
        Product2 p = new Product2(Name = sku, StockKeepingUnit = sku, IsActive = true);
        insert p;
        return p;
    }

    private static PricebookEntry insertPbe(Id productId) {
        // Guard: if a PBE for this product already exists in the standard
        // pricebook (org data visible in tests), reuse it.
        List<PricebookEntry> existing = [
            SELECT Id FROM PricebookEntry
            WHERE Pricebook2Id = :stdPricebookId()
            AND   Product2Id   = :productId
            AND   IsActive     = true
            LIMIT 1
        ];
        if (!existing.isEmpty()) return existing[0];

        PricebookEntry pbe = new PricebookEntry(
            Pricebook2Id = stdPricebookId(),
            Product2Id   = productId,
            UnitPrice    = 0,
            IsActive     = true
        );
        insert pbe;
        return pbe;
    }

    private static Quote insertQuote() {
        Account acc = new Account(
            Name            = 'Test HaaS Account',
            BillingStreet   = '141 Main Street South',
            BillingCity     = 'Brampton',
            BillingState    = 'ON',
            BillingPostalCode = 'L6Y 1N3',
            BillingCountry  = 'Canada'
        );
        insert acc;
        Opportunity opp = new Opportunity(
            Name      = 'Test HaaS Opp',
            AccountId = acc.Id,
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30)
        );
        insert opp;
        Quote q = new Quote(
            Name          = 'Test HaaS Quote',
            OpportunityId = opp.Id,
            Pricebook2Id  = stdPricebookId()
        );
        insert q;
        return q;
    }

    /**
     * Builds an in-memory QuoteLineItem without PricingTermCount.
     * PricingTermCount is a system-managed field that is not writable in Apex
     * (it throws "Field is not writeable: QuoteLineItem.PricingTermCount").
     * In live trigger context the system populates it; unit tests cover the
     * null-PTC skip branch and all paths that do not rely on PTC
     * (carryover pricing, description validation, pairing validation).
     */
    private static QuoteLineItem buildQli(
        Id quoteId, Id productId, Id pbeId, Decimal quantity, Decimal unitPrice
    ) {
        return new QuoteLineItem(
            QuoteId          = quoteId,
            Product2Id       = productId,
            PricebookEntryId = pbeId,
            Quantity         = quantity,
            UnitPrice        = unitPrice
        );
    }

    // =========================================================================
    // applyHaasPricing — early-return / skip guards
    // =========================================================================

    @isTest
    static void applyPricing_EmptyList_NoException() {
        Test.startTest();
        HaasPricingTriggerHandler.applyHaasPricing(new List<QuoteLineItem>());
        Test.stopTest();
        System.assert(true, 'Empty list must not throw');
    }

    @isTest
    static void applyPricing_NoHaasProductsInBatch_EarlyReturn() {
        // No Product2 rows with a HaaS SKU exist → skuByProductId is empty → early return.
        Product2 other = new Product2(Name = 'Other', StockKeepingUnit = 'OTHER-SKU', IsActive = true);
        insert other;
        PricebookEntry pbe = new PricebookEntry(
            Pricebook2Id = stdPricebookId(), Product2Id = other.Id, UnitPrice = 0, IsActive = true
        );
        insert pbe;
        Quote q = insertQuote();

        QuoteLineItem qli = buildQli(q.Id, other.Id, pbe.Id, 1, 50.00);

        Test.startTest();
        HaasPricingTriggerHandler.applyHaasPricing(new List<QuoteLineItem>{ qli });
        Test.stopTest();

        System.assertEquals(50.00, qli.UnitPrice, 'Non-HaaS SKU must never be touched');
    }

    @isTest
    static void applyPricing_NewBusiness_NullPtc_Skipped() {
        // PricingTermCount cannot be set in test context (system-managed field).
        // A new-business line will always hit the null-PTC skip guard in unit tests.
        Product2       hwProd = upsertProduct(HAAS_HARDWARE_SKU);
        PricebookEntry pbe    = insertPbe(hwProd.Id);
        Quote          q      = insertQuote();

        QuoteLineItem qli = buildQli(q.Id, hwProd.Id, pbe.Id, 1, 5.00);
        qli.HaaS_Hardware_Amount__c = 1200.00;
        // QuoteActionId null → new business; PricingTermCount null (cannot be set)

        Test.startTest();
        HaasPricingTriggerHandler.applyHaasPricing(new List<QuoteLineItem>{ qli });
        Test.stopTest();

        System.assertEquals(5.00, qli.UnitPrice,
            'UnitPrice must be unchanged when PricingTermCount is null (not settable in tests)');
    }

    @isTest
    static void applyPricing_HardwareMissingAmount_Skipped() {
        // Covers the path where the product IS a HaaS Hardware SKU but
        // HaaS_Hardware_Amount__c is null — handler skips after the PTC guard.
        Product2       hwProd = upsertProduct(HAAS_HARDWARE_SKU);
        PricebookEntry pbe    = insertPbe(hwProd.Id);
        Quote          q      = insertQuote();

        QuoteLineItem qli = buildQli(q.Id, hwProd.Id, pbe.Id, 1, 3.00);
        qli.HaaS_Hardware_Amount__c = null;

        Test.startTest();
        HaasPricingTriggerHandler.applyHaasPricing(new List<QuoteLineItem>{ qli });
        Test.stopTest();

        System.assertEquals(3.00, qli.UnitPrice,
            'UnitPrice must be unchanged when HaaS_Hardware_Amount__c is null');
    }

    // =========================================================================
    // applyHaasPricing — Renewal carryover (UnitPrice sourced from Asset.CurrentMrr)
    // =========================================================================

    @isTest
    static void applyPricing_RenewCarryover_WithAssetMrr_UnitPriceFromAsset() {
        Product2       hwProd = upsertProduct(HAAS_HARDWARE_SKU);
        PricebookEntry pbe    = insertPbe(hwProd.Id);
        Quote          q      = insertQuote();
        Account        acc    = [SELECT Id FROM Account LIMIT 1];

        Asset a = new Asset(
            Name       = 'HaaS Asset',
            AccountId  = acc.Id,
            Product2Id = hwProd.Id,
            CurrentMrr = 75.00
        );
        // CurrentMrr is a Revenue Cloud field with restricted FLS;
        // SYSTEM_MODE bypasses field-level security for test data setup.
        Database.insert(a, AccessLevel.SYSTEM_MODE);

        QuoteAction qa = new QuoteAction(Type = 'Renew', QuoteId = q.Id, SourceAssetId = a.Id);
        insert qa;

        QuoteLineItem qli = buildQli(q.Id, hwProd.Id, pbe.Id, 1, 0);
        qli.QuoteActionId           = qa.Id;
        qli.HaaS_Hardware_Amount__c = 900.00; // must be ignored; price comes from Asset

        Test.startTest();
        HaasPricingTriggerHandler.applyHaasPricing(new List<QuoteLineItem>{ qli });
        Test.stopTest();

        System.assertEquals(75.00, qli.UnitPrice,
            'Renewal carryover: UnitPrice must equal Asset.CurrentMrr, not amount/PTC');
    }

    @isTest
    static void applyPricing_RenewCarryover_NoSourceAsset_UnitPriceUnchanged() {
        Product2       hwProd = upsertProduct(HAAS_HARDWARE_SKU);
        PricebookEntry pbe    = insertPbe(hwProd.Id);
        Quote          q      = insertQuote();

        // Renew QuoteAction with no SourceAssetId → no MRR available
        QuoteAction qa = new QuoteAction(Type = 'Renew', QuoteId = q.Id);
        insert qa;

        QuoteLineItem qli = buildQli(q.Id, hwProd.Id, pbe.Id, 1, 42.00);
        qli.QuoteActionId = qa.Id;

        Test.startTest();
        HaasPricingTriggerHandler.applyHaasPricing(new List<QuoteLineItem>{ qli });
        Test.stopTest();

        System.assertEquals(42.00, qli.UnitPrice,
            'Renewal without SourceAsset MRR: UnitPrice must be left untouched');
    }

    @isTest
    static void applyPricing_AmendCarryover_UnitPriceUnchanged() {
        Product2       hwProd = upsertProduct(HAAS_HARDWARE_SKU);
        PricebookEntry pbe    = insertPbe(hwProd.Id);
        Quote          q      = insertQuote();

        QuoteAction qa = new QuoteAction(Type = 'Amend', QuoteId = q.Id);
        insert qa;

        QuoteLineItem qli = buildQli(q.Id, hwProd.Id, pbe.Id, 1, 99.00);
        qli.QuoteActionId = qa.Id;

        Test.startTest();
        HaasPricingTriggerHandler.applyHaasPricing(new List<QuoteLineItem>{ qli });
        Test.stopTest();

        System.assertEquals(99.00, qli.UnitPrice,
            'Amend carryover: UnitPrice must NOT be recalculated');
    }

    @isTest
    static void applyPricing_NoChangeCarryover_UnitPriceUnchanged() {
        Product2       implProd = upsertProduct(HAAS_IMPLEMENTATION_SKU);
        PricebookEntry pbe      = insertPbe(implProd.Id);
        Quote          q        = insertQuote();

        QuoteAction qa = new QuoteAction(Type = 'No Change', QuoteId = q.Id);
        insert qa;

        QuoteLineItem qli = buildQli(q.Id, implProd.Id, pbe.Id, 1, 55.00);
        qli.QuoteActionId = qa.Id;

        Test.startTest();
        HaasPricingTriggerHandler.applyHaasPricing(new List<QuoteLineItem>{ qli });
        Test.stopTest();

        System.assertEquals(55.00, qli.UnitPrice,
            'No Change carryover: UnitPrice must not be recalculated');
    }

    @isTest
    static void applyPricing_CancelCarryover_UnitPriceUnchanged() {
        Product2       implProd = upsertProduct(HAAS_IMPLEMENTATION_SKU);
        PricebookEntry pbe      = insertPbe(implProd.Id);
        Quote          q        = insertQuote();

        QuoteAction qa = new QuoteAction(Type = 'Cancel', QuoteId = q.Id);
        insert qa;

        QuoteLineItem qli = buildQli(q.Id, implProd.Id, pbe.Id, 1, 30.00);
        qli.QuoteActionId = qa.Id;

        Test.startTest();
        HaasPricingTriggerHandler.applyHaasPricing(new List<QuoteLineItem>{ qli });
        Test.stopTest();

        System.assertEquals(30.00, qli.UnitPrice,
            'Cancel carryover: UnitPrice must not be recalculated');
    }

    // =========================================================================
    // validateHardwareDescription
    // =========================================================================

    @isTest
    static void validateDesc_AmountSetNullDescription_ErrorAdded() {
        Product2       hwProd = upsertProduct(HAAS_HARDWARE_SKU);
        PricebookEntry pbe    = insertPbe(hwProd.Id);
        Quote          q      = insertQuote();

        QuoteLineItem qli = buildQli(q.Id, hwProd.Id, pbe.Id, 1, 0);
        qli.HaaS_Hardware_Amount__c = 1000.00;
        qli.Description = null;

        Test.startTest();
        HaasPricingTriggerHandler.validateHardwareDescription(new List<QuoteLineItem>{ qli });
        Test.stopTest();

        System.assert(qli.getErrors().size() > 0,
            'Field error must be added when amount is set but Description is null');
    }

    @isTest
    static void validateDesc_AmountSetBlankDescription_ErrorAdded() {
        Product2       hwProd = upsertProduct(HAAS_HARDWARE_SKU);
        PricebookEntry pbe    = insertPbe(hwProd.Id);
        Quote          q      = insertQuote();

        QuoteLineItem qli = buildQli(q.Id, hwProd.Id, pbe.Id, 1, 0);
        qli.HaaS_Hardware_Amount__c = 500.00;
        qli.Description = '   '; // whitespace only

        Test.startTest();
        HaasPricingTriggerHandler.validateHardwareDescription(new List<QuoteLineItem>{ qli });
        Test.stopTest();

        System.assert(qli.getErrors().size() > 0,
            'Field error must be added when Description is whitespace only');
    }

    @isTest
    static void validateDesc_AmountSetWithDescription_NoError() {
        Product2       hwProd = upsertProduct(HAAS_HARDWARE_SKU);
        PricebookEntry pbe    = insertPbe(hwProd.Id);
        Quote          q      = insertQuote();

        QuoteLineItem qli = buildQli(q.Id, hwProd.Id, pbe.Id, 1, 0);
        qli.HaaS_Hardware_Amount__c = 1000.00;
        qli.Description = 'Dell PowerEdge R750 x2';

        Test.startTest();
        HaasPricingTriggerHandler.validateHardwareDescription(new List<QuoteLineItem>{ qli });
        Test.stopTest();

        System.assertEquals(0, qli.getErrors().size(), 'No error when Description is populated');
    }

    @isTest
    static void validateDesc_NoAmount_SkipValidation() {
        Product2       hwProd = upsertProduct(HAAS_HARDWARE_SKU);
        PricebookEntry pbe    = insertPbe(hwProd.Id);
        Quote          q      = insertQuote();

        QuoteLineItem qli = buildQli(q.Id, hwProd.Id, pbe.Id, 1, 0);
        qli.HaaS_Hardware_Amount__c = null;
        qli.Description = null;

        Test.startTest();
        HaasPricingTriggerHandler.validateHardwareDescription(new List<QuoteLineItem>{ qli });
        Test.stopTest();

        System.assertEquals(0, qli.getErrors().size(),
            'Validation must not run when HaaS_Hardware_Amount__c is null');
    }

    @isTest
    static void validateDesc_ImplementationSku_AlwaysSkipped() {
        Product2       implProd = upsertProduct(HAAS_IMPLEMENTATION_SKU);
        PricebookEntry pbe      = insertPbe(implProd.Id);
        Quote          q        = insertQuote();

        QuoteLineItem qli = buildQli(q.Id, implProd.Id, pbe.Id, 1, 0);
        qli.Description = null;

        Test.startTest();
        HaasPricingTriggerHandler.validateHardwareDescription(new List<QuoteLineItem>{ qli });
        Test.stopTest();

        System.assertEquals(0, qli.getErrors().size(),
            'Implementation SKU is never subject to description validation');
    }

    @isTest
    static void validateDesc_EmptyList_NoException() {
        Test.startTest();
        HaasPricingTriggerHandler.validateHardwareDescription(new List<QuoteLineItem>());
        Test.stopTest();
        System.assert(true, 'Empty list must not throw');
    }

    // =========================================================================
    // validateHaasPairing — Update is always a no-op
    // =========================================================================

    @isTest
    static void validatePairing_Update_AlwaysNoOp() {
        Product2       hwProd   = upsertProduct(HAAS_HARDWARE_SKU);
        Product2       implProd = upsertProduct(HAAS_IMPLEMENTATION_SKU);
        PricebookEntry hwPbe    = insertPbe(hwProd.Id);
        PricebookEntry implPbe  = insertPbe(implProd.Id);
        Quote          q        = insertQuote();

        // Insert a balanced HW + Impl pair so the live insert trigger is satisfied.
        QuoteLineItem hwQli = new QuoteLineItem(
            QuoteId = q.Id, Product2Id = hwProd.Id, PricebookEntryId = hwPbe.Id,
            Quantity = 1, UnitPrice = 0, HaaS_Hardware_Amount__c = 600.00,
            Description = 'Test hardware description'
        );
        QuoteLineItem implQli = new QuoteLineItem(
            QuoteId = q.Id, Product2Id = implProd.Id, PricebookEntryId = implPbe.Id,
            Quantity = 1, UnitPrice = 0
        );
        insert new List<QuoteLineItem>{ hwQli, implQli };

        // Now test that a plain field-edit update on the persisted HW line
        // never triggers the pairing check (isInsert=false, isDelete=false).
        QuoteLineItem updated = hwQli.clone(true, false, false, false);
        updated.HaaS_Hardware_Amount__c = 700.00;

        Test.startTest();
        HaasPricingTriggerHandler.validateHaasPairing(
            new List<QuoteLineItem>{ updated },
            new Map<Id, QuoteLineItem>{ hwQli.Id => hwQli },
            false, false
        );
        Test.stopTest();

        System.assertEquals(0, updated.getErrors().size(),
            'isInsert=false, isDelete=false must never produce a pairing error');
    }

    // =========================================================================
    // validateHaasPairing — Insert
    // =========================================================================

    @isTest
    static void validatePairing_Insert_OneHwOneImpl_NoError() {
        Product2       hwProd   = upsertProduct(HAAS_HARDWARE_SKU);
        Product2       implProd = upsertProduct(HAAS_IMPLEMENTATION_SKU);
        PricebookEntry hwPbe    = insertPbe(hwProd.Id);
        PricebookEntry implPbe  = insertPbe(implProd.Id);
        Quote          q        = insertQuote();

        QuoteLineItem hwQli   = buildQli(q.Id, hwProd.Id,   hwPbe.Id,   1, 0);
        QuoteLineItem implQli = buildQli(q.Id, implProd.Id, implPbe.Id, 1, 0);

        Test.startTest();
        HaasPricingTriggerHandler.validateHaasPairing(
            new List<QuoteLineItem>{ hwQli, implQli }, null, true, false
        );
        Test.stopTest();

        System.assertEquals(0, hwQli.getErrors().size(),   'Balanced 1:1 — no error on HW');
        System.assertEquals(0, implQli.getErrors().size(), 'Balanced 1:1 — no error on Impl');
    }

    @isTest
    static void validatePairing_Insert_TwoHwTwoImpl_NoError() {
        Product2       hwProd   = upsertProduct(HAAS_HARDWARE_SKU);
        Product2       implProd = upsertProduct(HAAS_IMPLEMENTATION_SKU);
        PricebookEntry hwPbe    = insertPbe(hwProd.Id);
        PricebookEntry implPbe  = insertPbe(implProd.Id);
        Quote          q        = insertQuote();

        List<QuoteLineItem> lines = new List<QuoteLineItem>{
            buildQli(q.Id, hwProd.Id,   hwPbe.Id,   1, 0),
            buildQli(q.Id, hwProd.Id,   hwPbe.Id,   1, 0),
            buildQli(q.Id, implProd.Id, implPbe.Id, 1, 0),
            buildQli(q.Id, implProd.Id, implPbe.Id, 1, 0)
        };

        Test.startTest();
        HaasPricingTriggerHandler.validateHaasPairing(lines, null, true, false);
        Test.stopTest();

        for (QuoteLineItem qli : lines) {
            System.assertEquals(0, qli.getErrors().size(), 'Balanced 2:2 — no error');
        }
    }

    @isTest
    static void validatePairing_Insert_HwOnlyNoImpl_Error() {
        Product2       hwProd = upsertProduct(HAAS_HARDWARE_SKU);
        PricebookEntry hwPbe  = insertPbe(hwProd.Id);
        Quote          q      = insertQuote();

        QuoteLineItem hwQli = buildQli(q.Id, hwProd.Id, hwPbe.Id, 1, 0);

        Test.startTest();
        HaasPricingTriggerHandler.validateHaasPairing(
            new List<QuoteLineItem>{ hwQli }, null, true, false
        );
        Test.stopTest();

        System.assert(hwQli.getErrors().size() > 0, 'HW=1, Impl=0 must produce a pairing error');
    }

    @isTest
    static void validatePairing_Insert_ImplOnlyNoHw_Error() {
        Product2       implProd = upsertProduct(HAAS_IMPLEMENTATION_SKU);
        PricebookEntry implPbe  = insertPbe(implProd.Id);
        Quote          q        = insertQuote();

        QuoteLineItem implQli = buildQli(q.Id, implProd.Id, implPbe.Id, 1, 0);

        Test.startTest();
        HaasPricingTriggerHandler.validateHaasPairing(
            new List<QuoteLineItem>{ implQli }, null, true, false
        );
        Test.stopTest();

        System.assert(implQli.getErrors().size() > 0, 'HW=0, Impl=1 must produce a pairing error');
    }

    @isTest
    static void validatePairing_Insert_TwoHwOneImpl_Error() {
        Product2       hwProd   = upsertProduct(HAAS_HARDWARE_SKU);
        Product2       implProd = upsertProduct(HAAS_IMPLEMENTATION_SKU);
        PricebookEntry hwPbe    = insertPbe(hwProd.Id);
        PricebookEntry implPbe  = insertPbe(implProd.Id);
        Quote          q        = insertQuote();

        List<QuoteLineItem> lines = new List<QuoteLineItem>{
            buildQli(q.Id, hwProd.Id,   hwPbe.Id,   1, 0),
            buildQli(q.Id, hwProd.Id,   hwPbe.Id,   1, 0),
            buildQli(q.Id, implProd.Id, implPbe.Id, 1, 0)
        };

        Test.startTest();
        HaasPricingTriggerHandler.validateHaasPairing(lines, null, true, false);
        Test.stopTest();

        Boolean anyError = false;
        for (QuoteLineItem qli : lines) {
            if (qli.getErrors().size() > 0) anyError = true;
        }
        System.assert(anyError, 'HW=2, Impl=1 must produce a pairing error');
    }

    @isTest
    static void validatePairing_Insert_CarryoverRenew_Exempt() {
        // A carried-forward HW line (QuoteAction.Type = Renew, no matching Impl)
        // must be exempt from the pairing check.
        Product2       hwProd = upsertProduct(HAAS_HARDWARE_SKU);
        PricebookEntry hwPbe  = insertPbe(hwProd.Id);
        Quote          q      = insertQuote();

        QuoteAction qa = new QuoteAction(Type = 'Renew', QuoteId = q.Id);
        insert qa;

        QuoteLineItem hwQli = buildQli(q.Id, hwProd.Id, hwPbe.Id, 1, 0);
        hwQli.QuoteActionId = qa.Id;

        Test.startTest();
        HaasPricingTriggerHandler.validateHaasPairing(
            new List<QuoteLineItem>{ hwQli }, null, true, false
        );
        Test.stopTest();

        System.assertEquals(0, hwQli.getErrors().size(),
            'Renew carryover HW without a paired Impl must NOT produce a pairing error');
    }

    @isTest
    static void validatePairing_Insert_CarryoverAmend_Exempt() {
        Product2       implProd = upsertProduct(HAAS_IMPLEMENTATION_SKU);
        PricebookEntry implPbe  = insertPbe(implProd.Id);
        Quote          q        = insertQuote();

        QuoteAction qa = new QuoteAction(Type = 'Amend', QuoteId = q.Id);
        insert qa;

        QuoteLineItem implQli = buildQli(q.Id, implProd.Id, implPbe.Id, 1, 0);
        implQli.QuoteActionId = qa.Id;

        Test.startTest();
        HaasPricingTriggerHandler.validateHaasPairing(
            new List<QuoteLineItem>{ implQli }, null, true, false
        );
        Test.stopTest();

        System.assertEquals(0, implQli.getErrors().size(),
            'Amend carryover Impl without a paired HW must NOT produce a pairing error');
    }

    @isTest
    static void validatePairing_Insert_NewHwPlusCarryoverImpl_Error() {
        // Brand-new HW (QuoteActionId null) + carried-forward Impl (Renew):
        // carryover Impl is exempt and must NOT balance the new HW.
        Product2       hwProd   = upsertProduct(HAAS_HARDWARE_SKU);
        Product2       implProd = upsertProduct(HAAS_IMPLEMENTATION_SKU);
        PricebookEntry hwPbe    = insertPbe(hwProd.Id);
        PricebookEntry implPbe  = insertPbe(implProd.Id);
        Quote          q        = insertQuote();

        QuoteAction qa = new QuoteAction(Type = 'Renew', QuoteId = q.Id);
        insert qa;

        QuoteLineItem hwQli   = buildQli(q.Id, hwProd.Id,   hwPbe.Id,   1, 0);
        QuoteLineItem implQli = buildQli(q.Id, implProd.Id, implPbe.Id, 1, 0);
        implQli.QuoteActionId = qa.Id; // carryover — exempt

        Test.startTest();
        HaasPricingTriggerHandler.validateHaasPairing(
            new List<QuoteLineItem>{ hwQli, implQli }, null, true, false
        );
        Test.stopTest();

        System.assert(hwQli.getErrors().size() > 0,
            'New HW=1 with carryover Impl (exempt) must still produce a pairing error');
    }

    @isTest
    static void validatePairing_Insert_QuoteActionTypeAdd_TreatedAsNew() {
        // QuoteAction.Type = 'Add' is a genuine new addition — must be subject to pairing.
        Product2       hwProd = upsertProduct(HAAS_HARDWARE_SKU);
        PricebookEntry hwPbe  = insertPbe(hwProd.Id);
        Quote          q      = insertQuote();

        QuoteAction qa = new QuoteAction(Type = 'Add', QuoteId = q.Id);
        insert qa;

        QuoteLineItem hwQli = buildQli(q.Id, hwProd.Id, hwPbe.Id, 1, 0);
        hwQli.QuoteActionId = qa.Id;

        Test.startTest();
        HaasPricingTriggerHandler.validateHaasPairing(
            new List<QuoteLineItem>{ hwQli }, null, true, false
        );
        Test.stopTest();

        System.assert(hwQli.getErrors().size() > 0,
            'QuoteAction.Type = Add must be treated as new business and still require a paired Impl');
    }

    @isTest
    static void validatePairing_Insert_NoHaasSkus_NoError() {
        Product2 other = new Product2(Name = 'Other', StockKeepingUnit = 'OTHER', IsActive = true);
        insert other;
        PricebookEntry pbe = new PricebookEntry(
            Pricebook2Id = stdPricebookId(), Product2Id = other.Id, UnitPrice = 0, IsActive = true
        );
        insert pbe;
        Quote q = insertQuote();

        QuoteLineItem qli = buildQli(q.Id, other.Id, pbe.Id, 1, 0);

        Test.startTest();
        HaasPricingTriggerHandler.validateHaasPairing(
            new List<QuoteLineItem>{ qli }, null, true, false
        );
        Test.stopTest();

        System.assertEquals(0, qli.getErrors().size(), 'Non-HaaS lines must never get a pairing error');
    }

    // =========================================================================
    // validateHaasPairing — Delete
    // =========================================================================

    @isTest
    static void validatePairing_Delete_BothDeleted_NoError() {
        // Deleting HW + Impl together → 0:0 remaining → balanced.
        Product2       hwProd   = upsertProduct(HAAS_HARDWARE_SKU);
        Product2       implProd = upsertProduct(HAAS_IMPLEMENTATION_SKU);
        PricebookEntry hwPbe    = insertPbe(hwProd.Id);
        PricebookEntry implPbe  = insertPbe(implProd.Id);
        Quote          q        = insertQuote();

        QuoteLineItem hwQli = new QuoteLineItem(
            QuoteId = q.Id, Product2Id = hwProd.Id, PricebookEntryId = hwPbe.Id,
            Quantity = 1, UnitPrice = 0, HaaS_Hardware_Amount__c = 600.00,
            Description = 'Test hardware description'
        );
        QuoteLineItem implQli = new QuoteLineItem(
            QuoteId = q.Id, Product2Id = implProd.Id, PricebookEntryId = implPbe.Id,
            Quantity = 1, UnitPrice = 0
        );
        insert new List<QuoteLineItem>{ hwQli, implQli };

        Map<Id, QuoteLineItem> oldMap = new Map<Id, QuoteLineItem>{
            hwQli.Id => hwQli, implQli.Id => implQli
        };

        Test.startTest();
        HaasPricingTriggerHandler.validateHaasPairing(null, oldMap, false, true);
        Test.stopTest();

        System.assertEquals(0, hwQli.getErrors().size(),   'Deleting both: 0:0 — no error on HW');
        System.assertEquals(0, implQli.getErrors().size(), 'Deleting both: 0:0 — no error on Impl');
    }

    @isTest
    static void validatePairing_Delete_HwDeletedImplRemains_Error() {
        // Deleting only the HW while Impl remains → 0:1 → unbalanced.
        Product2       hwProd   = upsertProduct(HAAS_HARDWARE_SKU);
        Product2       implProd = upsertProduct(HAAS_IMPLEMENTATION_SKU);
        PricebookEntry hwPbe    = insertPbe(hwProd.Id);
        PricebookEntry implPbe  = insertPbe(implProd.Id);
        Quote          q        = insertQuote();

        QuoteLineItem hwQli = new QuoteLineItem(
            QuoteId = q.Id, Product2Id = hwProd.Id, PricebookEntryId = hwPbe.Id,
            Quantity = 1, UnitPrice = 0, HaaS_Hardware_Amount__c = 600.00,
            Description = 'Test hardware description'
        );
        QuoteLineItem implQli = new QuoteLineItem(
            QuoteId = q.Id, Product2Id = implProd.Id, PricebookEntryId = implPbe.Id,
            Quantity = 1, UnitPrice = 0
        );
        insert new List<QuoteLineItem>{ hwQli, implQli };

        Map<Id, QuoteLineItem> oldMap = new Map<Id, QuoteLineItem>{ hwQli.Id => hwQli };

        Test.startTest();
        HaasPricingTriggerHandler.validateHaasPairing(null, oldMap, false, true);
        Test.stopTest();

        System.assert(hwQli.getErrors().size() > 0,
            'Deleting HW while Impl remains (0 HW : 1 Impl) must block the delete');
    }

    @isTest
    static void validatePairing_Delete_ImplDeletedHwRemains_Error() {
        // Deleting only the Impl while HW remains → 1:0 → unbalanced.
        Product2       hwProd   = upsertProduct(HAAS_HARDWARE_SKU);
        Product2       implProd = upsertProduct(HAAS_IMPLEMENTATION_SKU);
        PricebookEntry hwPbe    = insertPbe(hwProd.Id);
        PricebookEntry implPbe  = insertPbe(implProd.Id);
        Quote          q        = insertQuote();

        QuoteLineItem hwQli = new QuoteLineItem(
            QuoteId = q.Id, Product2Id = hwProd.Id, PricebookEntryId = hwPbe.Id,
            Quantity = 1, UnitPrice = 0, HaaS_Hardware_Amount__c = 600.00,
            Description = 'Test hardware description'
        );
        QuoteLineItem implQli = new QuoteLineItem(
            QuoteId = q.Id, Product2Id = implProd.Id, PricebookEntryId = implPbe.Id,
            Quantity = 1, UnitPrice = 0
        );
        insert new List<QuoteLineItem>{ hwQli, implQli };

        Map<Id, QuoteLineItem> oldMap = new Map<Id, QuoteLineItem>{ implQli.Id => implQli };

        Test.startTest();
        HaasPricingTriggerHandler.validateHaasPairing(null, oldMap, false, true);
        Test.stopTest();

        System.assert(implQli.getErrors().size() > 0,
            'Deleting Impl while HW remains (1 HW : 0 Impl) must block the delete');
    }

    @isTest
    static void validatePairing_Delete_CarryoverRenewDeleted_Exempt() {
        // Deleting a Renew carryover line alone must be allowed — it was never
        // counted toward the pairing requirement in the first place.
        Product2       hwProd = upsertProduct(HAAS_HARDWARE_SKU);
        PricebookEntry hwPbe  = insertPbe(hwProd.Id);
        Quote          q      = insertQuote();

        QuoteAction qa = new QuoteAction(Type = 'Renew', QuoteId = q.Id);
        insert qa;

        QuoteLineItem hwQli = new QuoteLineItem(
            QuoteId = q.Id, Product2Id = hwProd.Id, PricebookEntryId = hwPbe.Id,
            Quantity = 1, UnitPrice = 0, HaaS_Hardware_Amount__c = 600.00,
            Description = 'Test hardware description', QuoteActionId = qa.Id
        );
        insert hwQli;

        Map<Id, QuoteLineItem> oldMap = new Map<Id, QuoteLineItem>{ hwQli.Id => hwQli };

        Test.startTest();
        HaasPricingTriggerHandler.validateHaasPairing(null, oldMap, false, true);
        Test.stopTest();

        System.assertEquals(0, hwQli.getErrors().size(),
            'Deleting a Renew carryover HW line must never trigger a pairing error');
    }

    @isTest
    static void validatePairing_Delete_NoHaasSkus_NoError() {
        Product2 other = new Product2(Name = 'Other', StockKeepingUnit = 'OTHER', IsActive = true);
        insert other;
        PricebookEntry pbe = new PricebookEntry(
            Pricebook2Id = stdPricebookId(), Product2Id = other.Id, UnitPrice = 0, IsActive = true
        );
        insert pbe;
        Quote q = insertQuote();

        QuoteLineItem qli = buildQli(q.Id, other.Id, pbe.Id, 1, 0);
        insert qli;

        Map<Id, QuoteLineItem> oldMap = new Map<Id, QuoteLineItem>{ qli.Id => qli };

        Test.startTest();
        HaasPricingTriggerHandler.validateHaasPairing(null, oldMap, false, true);
        Test.stopTest();

        System.assertEquals(0, qli.getErrors().size(), 'Non-HaaS delete must be fully ignored');
    }
}