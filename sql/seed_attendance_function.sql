CREATE OR REPLACE FUNCTION timetracking.seed_user_attendance(
    p_tenant_id        integer,
    p_user_id          integer,
    p_work_hours       numeric  DEFAULT 7,
    p_months           integer  DEFAULT 6,
    p_worked_days_base integer  DEFAULT 10,
    p_worked_days_step integer  DEFAULT 1,
    p_leave_days_base  integer  DEFAULT 1,
    p_leave_days_step  integer  DEFAULT 1,
    p_anchor_month     date     DEFAULT date_trunc('month', current_date)::date,
    p_day_start        time     DEFAULT '09:00',
    p_time_zone        text     DEFAULT 'UTC',
    p_updated_by       text     DEFAULT 'seed_user_attendance',
    p_replace          boolean  DEFAULT true
)
RETURNS TABLE (
    month_start      date,
    worked_days      integer,
    work_minutes     numeric,
    overtime_minutes numeric,
    leave_days       integer,
    vacation_days    numeric,
    sick_days        numeric
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_first_month   date := (date_trunc('month', p_anchor_month) - make_interval(months => p_months - 1))::date;
    v_window_start  date := v_first_month;
    v_window_end    date := (date_trunc('month', p_anchor_month) + interval '1 month - 1 day')::date;
    v_month         record;
    v_worked        integer;
    v_leave         integer;
    v_business_days integer;
BEGIN
    IF p_months < 1 THEN
        RAISE EXCEPTION 'p_months must be >= 1, got %', p_months;
    END IF;

    IF p_replace THEN
        DELETE FROM timetracking.att_work_sessions
         WHERE tenant_id = p_tenant_id
           AND user_id = p_user_id
           AND work_date BETWEEN v_window_start AND v_window_end;

        DELETE FROM timetracking.att_user_leave_days
         WHERE tenant_id = p_tenant_id
           AND user_id = p_user_id
           AND leave_date BETWEEN v_window_start AND v_window_end;
    END IF;

    FOR v_month IN
        SELECT gs::date AS first_day,
               (row_number() OVER (ORDER BY gs) - 1)::integer AS idx
          FROM generate_series(v_first_month,
                               date_trunc('month', p_anchor_month)::date,
                               interval '1 month') AS gs
    LOOP
        v_worked := p_worked_days_base + v_month.idx * p_worked_days_step;
        v_leave  := p_leave_days_base  + v_month.idx * p_leave_days_step;

        SELECT count(*)::integer
          INTO v_business_days
          FROM generate_series(v_month.first_day,
                               (v_month.first_day + interval '1 month - 1 day')::date,
                               interval '1 day') AS d
         WHERE extract(isodow FROM d) < 6;

        IF v_worked + v_leave > v_business_days THEN
            RAISE EXCEPTION
                'month % needs % business days (% worked + % leave) but has only %',
                to_char(v_month.first_day, 'YYYY-MM'), v_worked + v_leave,
                v_worked, v_leave, v_business_days;
        END IF;

        INSERT INTO timetracking.att_work_sessions
            (tenant_id, user_id, work_date, open_session_date, close_session_date,
             updated_by, sys_update_date)
        SELECT p_tenant_id,
               p_user_id,
               d.day,
               (d.day + p_day_start) AT TIME ZONE p_time_zone,
               (d.day + p_day_start) AT TIME ZONE p_time_zone
                   + make_interval(mins => round(p_work_hours * 60)::integer),
               p_updated_by,
               now()
          FROM (
            SELECT gs::date AS day,
                   row_number() OVER (ORDER BY gs) AS n
              FROM generate_series(v_month.first_day,
                                   (v_month.first_day + interval '1 month - 1 day')::date,
                                   interval '1 day') AS gs
             WHERE extract(isodow FROM gs) < 6
          ) AS d
         WHERE d.n <= v_worked;

        INSERT INTO timetracking.att_user_leave_days
            (tenant_id, user_id, leave_date, vacation_amount, sick_amount,
             updated_by, sys_update_date)
        SELECT p_tenant_id,
               p_user_id,
               d.day,
               CASE WHEN (d.n - v_worked) % 2 = 1 THEN 1.0 END,
               CASE WHEN (d.n - v_worked) % 2 = 0 THEN 1.0 END,
               p_updated_by,
               now()
          FROM (
            SELECT gs::date AS day,
                   row_number() OVER (ORDER BY gs) AS n
              FROM generate_series(v_month.first_day,
                                   (v_month.first_day + interval '1 month - 1 day')::date,
                                   interval '1 day') AS gs
             WHERE extract(isodow FROM gs) < 6
          ) AS d
         WHERE d.n > v_worked
           AND d.n <= v_worked + v_leave
        ON CONFLICT (tenant_id, user_id, leave_date) DO UPDATE
            SET vacation_amount = excluded.vacation_amount,
                sick_amount     = excluded.sick_amount,
                updated_by      = excluded.updated_by,
                sys_update_date = excluded.sys_update_date;
    END LOOP;

    RETURN QUERY
    WITH months AS (
        SELECT gs::date AS first_day
          FROM generate_series(v_first_month,
                               date_trunc('month', p_anchor_month)::date,
                               interval '1 month') AS gs
    ),
    sessions AS (
        SELECT date_trunc('month', ws.work_date)::date AS first_day,
               count(DISTINCT ws.work_date)::integer AS worked_days,
               sum(extract(epoch FROM (ws.close_session_date - ws.open_session_date)) / 60)::numeric AS work_minutes,
               sum(greatest(extract(epoch FROM (ws.close_session_date - ws.open_session_date)) / 60 - 480, 0))::numeric AS overtime_minutes
          FROM timetracking.att_work_sessions ws
         WHERE ws.tenant_id = p_tenant_id
           AND ws.user_id = p_user_id
           AND ws.work_date BETWEEN v_window_start AND v_window_end
         GROUP BY 1
    ),
    leaves AS (
        SELECT date_trunc('month', ld.leave_date)::date AS first_day,
               count(*)::integer AS leave_days,
               coalesce(sum(ld.vacation_amount), 0)::numeric AS vacation_days,
               coalesce(sum(ld.sick_amount), 0)::numeric AS sick_days
          FROM timetracking.att_user_leave_days ld
         WHERE ld.tenant_id = p_tenant_id
           AND ld.user_id = p_user_id
           AND ld.leave_date BETWEEN v_window_start AND v_window_end
         GROUP BY 1
    )
    SELECT m.first_day,
           coalesce(s.worked_days, 0),
           coalesce(s.work_minutes, 0),
           coalesce(s.overtime_minutes, 0),
           coalesce(l.leave_days, 0),
           coalesce(l.vacation_days, 0),
           coalesce(l.sick_days, 0)
      FROM months m
      LEFT JOIN sessions s ON s.first_day = m.first_day
      LEFT JOIN leaves   l ON l.first_day = m.first_day
     ORDER BY m.first_day;
END;
$$;

