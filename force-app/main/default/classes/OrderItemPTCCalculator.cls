/**
 * Decides the PricingTermCount for a recurring OrderItem. Used by OrderItemPTCTrigger.
 *
 * Rule (per OrderItem, ramp and non-ramp alike - each ramp line links to its own
 * segment QuoteLineItem):
 *   1. OrderItem dates still equal its QuoteLineItem's dates -> use the QLI's
 *      PricingTermCount, so the order matches the quote exactly (e.g. 0.98 on MTM lines).
 *   2. Otherwise (no QLI, QLI has no term, or the order dates were moved, e.g. by the
 *      Change Contract Start Date flow) -> calculate the term from the OrderItem's own
 *      ServiceDate / EndDate.
 *
 * Before 2026-10-02 the QLI value always won, so after a start-date change the term
 * reverted to the quote's value while the dates covered a different period.
 */
public with sharing class OrderItemPTCCalculator {

    /**
     * @return the PricingTermCount the OrderItem should carry, or null when its dates are missing
     */
    public static Decimal resolve(Date serviceDate, Date endDate, Date qliStartDate, Date qliEndDate, Decimal qliPtc) {
        if (serviceDate == null || endDate == null) return null;
        Boolean datesMatchQuote = qliStartDate == serviceDate && qliEndDate == endDate;
        if (datesMatchQuote && qliPtc != null && qliPtc > 0) {
            return qliPtc;
        }
        return calcPTC(serviceDate, endDate);
    }

    /**
     * fullMonths + remainingDays / daysInThatCalendarMonth, EndDate inclusive, 2 decimals
     * (the field's scale). Same formula as SetOrderItemPricingTerm.calcPTC.
     */
    public static Decimal calcPTC(Date serviceDate, Date endDate) {
        if (serviceDate == null || endDate == null) return null;
        Integer fullMonths = serviceDate.monthsBetween(endDate);
        Date    base       = serviceDate.addMonths(fullMonths);
        // monthsBetween can overshoot when endDate falls before the same day-of-month
        while (fullMonths > 0 && base > endDate) {
            fullMonths--;
            base = serviceDate.addMonths(fullMonths);
        }
        Integer remainDays  = base.daysBetween(endDate.addDays(1)); // inclusive end
        Date    monthStart  = Date.newInstance(base.year(), base.month(), 1);
        Integer daysInMonth = monthStart.daysBetween(monthStart.addMonths(1));
        return (fullMonths + (Decimal) remainDays / daysInMonth).setScale(2, System.RoundingMode.HALF_UP);
    }
}