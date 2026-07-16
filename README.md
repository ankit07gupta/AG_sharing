# Property rental Booking

Build a model that produces at least 1 row per booking transaction event (creation/correction/cancellation) with Required columns
1. Transaction_month
2. original_booking_id
3. booking_id
4. transaction_type (CREATION / CORRECTION / CANCELLATION)
5. revenue (signed: positive for creation, negative for reversals)
6. commissionable_revenue (signed; for Part 1 this will typically equal signed event revenue, but only for the listing’s first booking logic)
7. sales_owner
8. listing_id
9. landlord_id

