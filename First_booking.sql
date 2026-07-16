-- part 1 case study by Ankit Gupta
-- CTE 1: booking_creation
-- Generates the 'CREATION' event for every booking version.
-- Revenue remains positive (as invoiced).
WITH booking_creation AS (
    SELECT 
        b.landlord_id, listing_id, tenant_id, l.sales_owner,
        original_booking_id, booking_id, original_booking_created_at, 
        actual_booking_created_at AS created_at, 
        date_trunc(date(actual_booking_created_at), month) AS transaction_month, 
        revenue, 
        'CREATION' AS transaction_type,
        -- Ranks versions within the same booking thread to track modifications
        RANK() OVER(PARTITION BY original_booking_id ORDER BY actual_booking_created_at) AS booking_modification_count
    FROM wunderflats.bookings b
    LEFT JOIN wunderflats.landlords l ON b.landlord_id = l.landlord_id
),

-- CTE 2: booking_modification
-- Generates the reversal events ('CORRECTION' or 'CANCELLATION').
-- Reverses the revenue (multiplies by -1) to balance the original creation.
booking_modification AS (
    SELECT 
        b.landlord_id, listing_id, tenant_id, l.sales_owner,
        original_booking_id, booking_id, original_booking_created_at, 
        canceled_at AS created_at, 
        date_trunc(date(canceled_at), month) AS transaction_month, 
        cancellation_reason AS transaction_type, 
        (revenue * (-1)) AS revenue 
    FROM wunderflats.bookings b
    LEFT JOIN wunderflats.landlords l ON b.landlord_id = l.landlord_id
    WHERE canceled_at IS NOT NULL
),

-- CTE 3: all_booking_events
-- UNIONs creations and modifications to build the base transaction ledger.
-- Guarantees at least 1 row per event.
all_booking_events AS (
    SELECT transaction_month, original_booking_id, booking_id, created_at, transaction_type, revenue, sales_owner, listing_id, landlord_id
    FROM booking_creation
    GROUP BY ALL
    UNION ALL
    SELECT transaction_month, original_booking_id, booking_id, created_at, transaction_type, revenue, sales_owner, listing_id, landlord_id
    FROM booking_modification
    GROUP BY ALL
),

-- CTE 4: listing_all_bookings
-- Prepares creation events for a unified listing timeline. 
-- Maps the event_created_at to the actual_booking_created_at.
listing_all_bookings AS (
    SELECT 
        listing_id, original_booking_id, booking_id, original_booking_created_at, 
        actual_booking_created_at, 
        actual_booking_created_at AS event_created_at, -- Timeline anchor for creation
        date_trunc(date(actual_booking_created_at), month) AS transaction_month, 
        'CREATION' AS transaction_type, revenue, canceled_at
    FROM wunderflats.bookings
    GROUP BY ALL
),

-- CTE 5: listing_cancel_bookings
-- Prepares cancellation events for the unified listing timeline.
-- Maps the event_created_at to the canceled_at timestamp.
listing_cancel_bookings AS (
    SELECT 
        listing_id, original_booking_id, booking_id, original_booking_created_at, 
        actual_booking_created_at, 
        canceled_at AS event_created_at, -- Timeline anchor for cancellation
        date_trunc(date(canceled_at), month) AS transaction_month, 
        cancellation_reason AS transaction_type, revenue, canceled_at
    FROM wunderflats.bookings
    WHERE canceled_at IS NOT NULL 
    GROUP BY ALL
),

-- CTE 6: listing_all_events
-- Combines creations and cancellations into a single chronological timeline per listing.
listing_all_events AS (
    SELECT * FROM listing_all_bookings
    UNION ALL
    SELECT * FROM listing_cancel_bookings
),

-- CTE 7: listing_cancel_event
-- Identifies the absolute final cancellation date for a specific booking thread.
listing_cancel_event AS (
    SELECT 
        listing_id, original_booking_id, 
        max(canceled_at) AS real_canceled_at 
    FROM wunderflats.bookings
    WHERE canceled_at IS NOT NULL AND cancellation_reason = 'CANCELLATION'
    GROUP BY ALL
),

-- CTE 8: listing_all_events_ranked
-- Joins the timeline with the final cancellation dates and assigns chronological order.
listing_all_events_ranked AS (
    SELECT 
        a.listing_id, a.original_booking_id, booking_id, original_booking_created_at, 
        actual_booking_created_at, event_created_at, transaction_month, 
        transaction_type, revenue, canceled_at, real_canceled_at,
        RANK() OVER(PARTITION BY a.original_booking_id ORDER BY event_created_at DESC) AS latest_modification_booking,
        -- Ranks the threads themselves
        DENSE_RANK() OVER(PARTITION BY a.listing_id ORDER BY original_booking_created_at) AS original_booking_rank,
        -- Ranks every single event sequentially across the listing
        RANK() OVER(PARTITION BY a.listing_id ORDER BY original_booking_created_at, event_created_at) AS initial_bookings_order
    FROM listing_all_events a
    LEFT JOIN listing_cancel_event b ON a.listing_id = b.listing_id AND a.original_booking_id = b.original_booking_id
    GROUP BY ALL
),

-- CTE 9: listing_first_success_booking
-- Finds the definitive first "successful" booking for a listing.
-- Defined as never canceled OR surviving for > 3 months.
listing_first_success_booking AS ( 
    SELECT 
        listing_id, original_booking_id, booking_id, original_booking_created_at, 
        actual_booking_created_at, cancellation_reason, revenue
    FROM wunderflats.bookings
    WHERE canceled_at IS NULL OR date_diff(date(canceled_at), date(actual_booking_created_at), month) > 3
    QUALIFY RANK() OVER(PARTITION BY listing_id ORDER BY original_booking_created_at, actual_booking_created_at) = 1
),

-- CTE 10: all_initial
-- Flags all events that belong to a booking that occurred BEFORE or IS the first successful booking.
all_initial AS (
    SELECT 
        b.*, 
        CASE 
            WHEN f.listing_id IS NOT NULL AND b.original_booking_created_at <= f.original_booking_created_at THEN 1 
            WHEN f.listing_id IS NULL THEN 1 
            ELSE 0 
        END AS all_initial_bookings_flag, 
        CASE WHEN b.booking_id = f.booking_id THEN 1 ELSE 0 END AS eligible_first_booking
    FROM listing_all_events_ranked b
    LEFT JOIN listing_first_success_booking f ON b.listing_id = f.listing_id
    GROUP BY ALL
),

-- CTE 11: all_initial_bookings
-- The core logic to determine if a booking is the active "first booking" at the time of its event.
all_initial_bookings AS (
    SELECT 
        b.*, 
        n.booking_id AS next_first_booking_id, 
        n.canceled_at AS next_first_booking_canceled_at, 
        n.revenue AS next_first_booking_revenue,
        -- A booking is eligible for commission if it's the very first thread (rank=1) 
        -- OR if there is no prior active thread currently occupying the listing (n2 is null)
        CASE 
            WHEN b.original_booking_rank = 1 THEN 1 
            WHEN n2.booking_id IS NULL THEN 1 
            ELSE 0 
        END AS elgible_for_commission
    FROM all_initial b
    -- n: Looks forward to find the replacement CREATION event that immediately follows a CANCELLATION
    LEFT JOIN all_initial n 
        ON b.listing_id = n.listing_id 
        AND n.original_booking_rank > b.original_booking_rank 
        AND b.event_created_at > n.event_created_at 
        AND (n.canceled_at IS NULL OR n.canceled_at > b.event_created_at) 
        AND b.transaction_type = 'CANCELLATION' 
        AND n.transaction_type = 'CREATION' 
        AND n.all_initial_bookings_flag = 1
    -- n2: Looks backward to ensure there isn't already an active booking thread blocking this one
    LEFT JOIN all_initial n2 
        ON b.listing_id = n2.listing_id 
        AND b.original_booking_rank > 1 
        AND n2.original_booking_rank < b.original_booking_rank 
        AND n2.event_created_at < b.event_created_at 
        AND (n2.real_canceled_at IS NULL OR n2.real_canceled_at > b.event_created_at) 
        AND b.transaction_type = 'CREATION' 
        AND n2.transaction_type = 'CREATION' 
        AND n2.all_initial_bookings_flag = 1
    WHERE b.all_initial_bookings_flag = 1
    GROUP BY ALL
),

-- CTE 12: commission
-- Calculates the actual signed commissionable revenue amount.
commission AS (
    SELECT 
        a.listing_id, a.original_booking_id, a.booking_id, a.original_booking_created_at, 
        a.actual_booking_created_at, a.transaction_month, a.transaction_type, a.revenue, a.canceled_at,
        a.all_initial_bookings_flag, a.eligible_first_booking, a.initial_bookings_order,
        CASE 
            -- Standard creation: Full revenue
            WHEN elgible_for_commission = 1 AND transaction_type = 'CREATION' THEN revenue 
            -- Correction: Full reversal
            WHEN elgible_for_commission = 1 AND transaction_type = 'CORRECTION' THEN (revenue * (-1))
            -- Cancellation: Calculate the delta between the replacement booking and this cancelled booking
            WHEN elgible_for_commission = 1 AND transaction_type = 'CANCELLATION' THEN coalesce(next_first_booking_revenue, 0) - revenue
            ELSE 0 
        END AS commission
    FROM all_initial_bookings a
    WHERE a.all_initial_bookings_flag = 1
    GROUP BY ALL
)

-- Final SELECT
-- Joins the base event ledger (all_booking_events) with the calculated commission ledger
SELECT 
    b.transaction_month, 
    b.original_booking_id, 
    b.booking_id, 
    b.transaction_type, 
    b.revenue, 
    coalesce(c.commission, 0) AS commissionable_revenue,
    b.sales_owner, 
    b.listing_id, 
    b.landlord_id
FROM all_booking_events b
-- Joins on booking_id AND transaction_type to ensure the commission calculation maps to the exact correct event (Creation/Cancellation/Correction)
LEFT JOIN commission c 
    ON b.booking_id = c.booking_id AND b.transaction_type = c.transaction_type 
GROUP BY ALL;
