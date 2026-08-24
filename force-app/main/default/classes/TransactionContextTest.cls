@isTest
private class TransactionContextTest {

    @isTest
    static void testDefaultConstructor() {
        TransactionContext tc = new TransactionContext();
        System.assertEquals(null, tc.quoteType, 'quoteType should default to null');
        System.assertEquals(null, tc.contractTerm, 'contractTerm should default to null');
        System.assertEquals(null, tc.quoteStartDate, 'quoteStartDate should default to null');
        System.assertEquals(null, tc.bookingDate, 'bookingDate should default to null');
    }

    @isTest
    static void testIsNewBusiness_trueWhenQuoteTypeNull() {
        TransactionContext tc = new TransactionContext();
        tc.quoteType = null;
        System.assertEquals(true, tc.isNewBusiness(), 'Null quoteType should mean New Business');
    }

    @isTest
    static void testIsNewBusiness_falseWhenQuoteTypeSet() {
        TransactionContext tc = new TransactionContext();
        tc.quoteType = 'Amend';
        System.assertEquals(false, tc.isNewBusiness(), 'Non-null quoteType should not be New Business');
    }

    @isTest
    static void testIsAmend_true() {
        TransactionContext tc = new TransactionContext();
        tc.quoteType = 'Amend';
        System.assertEquals(true, tc.isAmend(), 'quoteType Amend should return true for isAmend');
    }

    @isTest
    static void testIsAmend_false() {
        TransactionContext tc = new TransactionContext();
        tc.quoteType = 'Renew';
        System.assertEquals(false, tc.isAmend(), 'quoteType Renew should return false for isAmend');
    }

    @isTest
    static void testIsCancel_true() {
        TransactionContext tc = new TransactionContext();
        tc.quoteType = 'Cancel';
        System.assertEquals(true, tc.isCancel(), 'quoteType Cancel should return true for isCancel');
    }

    @isTest
    static void testIsCancel_false() {
        TransactionContext tc = new TransactionContext();
        tc.quoteType = 'Amend';
        System.assertEquals(false, tc.isCancel(), 'quoteType Amend should return false for isCancel');
    }

    @isTest
    static void testFieldAssignment() {
        TransactionContext tc = new TransactionContext();
        tc.quoteType = 'Renew';
        tc.contractTerm = 12;
        tc.quoteStartDate = '2026-01-01';
        tc.bookingDate = '2026-01-05';

        System.assertEquals('Renew', tc.quoteType);
        System.assertEquals(12, tc.contractTerm);
        System.assertEquals('2026-01-01', tc.quoteStartDate);
        System.assertEquals('2026-01-05', tc.bookingDate);
    }
}