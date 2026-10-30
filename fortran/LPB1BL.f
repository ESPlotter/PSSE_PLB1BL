!=======================================================================
! LPB1BL  --  table-driven load characteristic for PSS/E
!
! What it does
!   Coordinated (IT=1) USRLOD characteristic.  Once the simulation
!   clock reaches the first row of a demand table, the static PSS/E
!   load at the bus is overridden by the active and reactive demand
!   listed in that table.  Every row of the table holds
!
!       instant [s]    active demand [MW]    reactive demand [Mvar]
!
!   separated by blanks, commas or any mix of the two.  Instants have
!   to grow strictly from one row to the next.  Between two rows the
!   demand is ramped linearly, and after the last row the final
!   demand is frozen.
!
!   Each overridden component then passes through its own first-order
!   lag.  A lag whose time constant is below four integration steps
!   is skipped, so the component follows the table directly.
!
! DYR record (load '1' at bus 1, both lags switched off)
!
!   1 'USRLOD' '1' 'LPB1BL' 12 1 3 2 0 8 0  1 1 'sample'  0.0 0.0 /
!
! Shared integer data
!   ICON(m)      1: table drives active demand, 0: PSS/E keeps it
!   ICON(m+1)    1: table drives reactive demand, 0: PSS/E keeps it
!   CHRICN(m+2)  table name; the reader appends the .lpb extension
!
! Real data
!   CON(j)       Tfp, lag time constant for active demand [s]
!   CON(j+1)     Tfq, lag time constant for reactive demand [s]
!
! Private VARs (system per unit unless stated), with the name of the
! offset that addresses each one in the code
!   VAR(l)    var_init_p     active demand seen at initialization
!   VAR(l+1)  var_init_q     reactive demand seen at initialization
!   VAR(l+2)  var_prev_p     active lag output at the preceding instant
!   VAR(l+3)  var_prev_q     reactive lag output at the preceding
!                            instant
!   VAR(l+4)  var_lag_p      active lag output at the current instant
!   VAR(l+5)  var_lag_q      reactive lag output at the current instant
!   VAR(l+6)  var_prev_time  preceding instant [s]
!   VAR(l+7)  var_this_time  current instant [s]; holds not_started
!                            until the table takes over
!
! Vocabulary used in the names
!   static demand  the ordinary PSS/E load of the bus (constant power,
!                  current and admittance parts) at the present bus
!                  voltage.  PSS/E has already injected it.
!   target demand  the demand this model wants on the bus: the lagged
!                  table value, or the static demand while the table
!                  is not in control.
!   _pu, _s        system per unit, seconds.
!
! Access to PSS/E data
!   Every PSS/E array element or scalar (ICON, CHRICN, CON, VAR, TIME,
!   DELT, SBASE, VOLT, CURNT, CLODFR...) is copied to a local variable
!   before it is used, and results are written back from a local
!   variable.  No PSS/E data is passed directly to a routine.  The
!   PSS/E 36 build turns each read into GET_xxx and each write into
!   CALL SET_xxx, so the converted source stays one plain call per
!   line.
!
! Start-up rule
!   STRT solves the network once before it runs MODE 1, so the network
!   entry can be reached while the VARs still hold leftovers.  The
!   table is therefore only honoured after MODE 1 has stamped the
!   start instant and the clock has moved beyond it.  Until then the
!   network entry adds nothing and never touches the VARs.
!=======================================================================
      SUBROUTINE LPB1BL(load_index, shared_slot, private_slot)
      INCLUDE 'COMON4.INS'

! Arguments passed by PSS/E
      INTEGER load_index     ! load index in the PSS/E load arrays
      INTEGER shared_slot    ! LDSTRT column with the first CON and ICON
      INTEGER private_slot   ! LDSTR2 column with the first private VAR

! Position of each private VAR relative to VAR(l); see the header.
      INTEGER var_init_p, var_init_q, var_prev_p, var_prev_q
      INTEGER var_lag_p, var_lag_q, var_prev_time, var_this_time
      PARAMETER (var_init_p = 0, var_init_q = 1)
      PARAMETER (var_prev_p = 2, var_prev_q = 3)
      PARAMETER (var_lag_p = 4, var_lag_q = 5)
      PARAMETER (var_prev_time = 6, var_this_time = 7)

! Value held by the time VARs until the table takes over.
      REAL not_started
      PARAMETER (not_started = -1.0E10)

! Demand table, read once and shared by every load using this model.
      INTEGER max_table_rows       ! capacity of the row arrays
      PARAMETER (max_table_rows = 100000)
      REAL row_time_s(max_table_rows)  ! instant of each row [s]
      REAL row_p_pu(max_table_rows)    ! active demand of each row
      REAL row_q_pu(max_table_rows)    ! reactive demand of each row
      INTEGER table_row_count      ! rows accepted; 0 keeps static load
      INTEGER table_segment        ! first row of the last segment used
      LOGICAL table_read_done      ! .TRUE. once a read has been tried
      REAL mode1_time_s            ! TIME stamped by the last MODE 1
      SAVE row_time_s, row_p_pu, row_q_pu, table_row_count
      SAVE table_segment, table_read_done, mode1_time_s
      DATA table_row_count /0/, table_segment /1/
      DATA table_read_done /.FALSE./, mode1_time_s /1.0E30/

! Working values of the present call
      INTEGER first_icon           ! ICON(first_icon) is ICON 1
      INTEGER first_con            ! CON(first_con) is CON 1 (Tfp)
      INTEGER first_var            ! VAR(first_var) is VAR(l)
      INTEGER bus_index            ! internal bus index of the load

! Local copies of the PSS/E data used in the present call
      INTEGER use_table_p          ! ICON 1: 1 when P follows the table
      INTEGER use_table_q          ! ICON 2: 1 when Q follows the table
      CHARACTER*32 table_name      ! ICON 3: table name without .lpb
      REAL tfp_s                   ! CON 1: active demand lag [s]
      REAL tfq_s                   ! CON 2: reactive demand lag [s]
      REAL system_mva              ! SBASE: system MVA base
      REAL time_now_s              ! TIME: simulation time of this call
      REAL time_step_s             ! DELT: integration time step [s]
      INTEGER log_unit             ! LPDEV: unit of the PSS/E log
      REAL previous_p_pu           ! VAR(l+2): preceding active output
      REAL previous_q_pu           ! VAR(l+3): preceding reactive output
      REAL lag_p_pu                ! VAR(l+4): active lag output
      REAL lag_q_pu                ! VAR(l+5): reactive lag output
      REAL prev_time_s             ! VAR(l+6): preceding instant [s]
      REAL this_time_s             ! VAR(l+7): current instant [s]
      COMPLEX bus_voltage_phasor   ! VOLT: complex voltage of the bus
      COMPLEX bus_current_pu       ! CURNT: current injected at the bus

! Values worked out in the present call
      REAL bus_voltage_pu          ! voltage magnitude at the load bus
      REAL low_voltage_factor      ! PSS/E reduction below PQBRAK
      REAL static_p_pu             ! active part of the static demand
      REAL static_q_pu             ! reactive part of the static demand
      REAL table_p_pu              ! active table demand at TIME
      REAL table_q_pu              ! reactive table demand at TIME
      REAL target_p_pu             ! active part of the target demand
      REAL target_q_pu             ! reactive part of the target demand
      REAL lag_step_s              ! time since the preceding instant
      REAL lag_bypass_s            ! lags shorter than this are skipped
      COMPLEX static_demand_pu     ! static P + jQ already on the bus
      COMPLEX target_demand_pu     ! P + jQ the model wants on the bus
      LOGICAL table_in_control     ! .TRUE. when the table drives load
      REAL lpb1bl_lag_output
      EXTERNAL lpb1bl_lag_output, lpb1bl_table_fetch
      EXTERNAL lpb1bl_table_lookup, lpb1bl_base_demand

!-----------------------------------------------------------------------
! Main entry.  Only MODE 1 does work here: fetch the table if nobody
! has done it yet, stamp the start instant and prime the VARs.
!-----------------------------------------------------------------------
      IF (MODE .EQ. 1) THEN
         first_icon = LDSTRT(2,shared_slot)
         use_table_p = ICON(first_icon)
         use_table_q = ICON(first_icon+1)
         time_now_s = TIME
         IF (.NOT. table_read_done) THEN
            table_name = CHRICN(first_icon+2)
            system_mva = SBASE
            log_unit = LPDEV
            CALL lpb1bl_table_fetch(table_name, use_table_p,
     &         use_table_q, max_table_rows, table_row_count,
     &         row_time_s, row_p_pu, row_q_pu, system_mva, log_unit)
            table_read_done = .TRUE.
         ENDIF
         mode1_time_s = time_now_s

         bus_index = NUMLOD(load_index)
         IF (bus_index .GT. 0) THEN
            first_var = LDSTR2(2,private_slot)
            CALL lpb1bl_base_demand(load_index, bus_index,
     &         bus_voltage_pu, static_demand_pu)
            static_p_pu = REAL(static_demand_pu)
            static_q_pu = AIMAG(static_demand_pu)
            VAR(first_var+var_init_p) = static_p_pu
            VAR(first_var+var_init_q) = static_q_pu
            VAR(first_var+var_prev_p) = static_p_pu
            VAR(first_var+var_prev_q) = static_q_pu
            VAR(first_var+var_lag_p)  = static_p_pu
            VAR(first_var+var_lag_q)  = static_q_pu
            VAR(first_var+var_prev_time) = not_started
            VAR(first_var+var_this_time) = not_started
         ENDIF
      ENDIF
      RETURN

!-----------------------------------------------------------------------
! Network entry.  PSS/E comes here on every network iteration, after
! SITER has already injected the static load held in CLODFR.  The
! entry works out the target demand and injects only the gap between
! that demand and the static one.
!-----------------------------------------------------------------------
      ENTRY TPB1BL(load_index, shared_slot, private_slot)

      first_icon = LDSTRT(2,shared_slot)
      use_table_p = ICON(first_icon)
      use_table_q = ICON(first_icon+1)
      IF (.NOT. table_read_done) THEN
         table_name = CHRICN(first_icon+2)
         system_mva = SBASE
         log_unit = LPDEV
         CALL lpb1bl_table_fetch(table_name, use_table_p,
     &      use_table_q, max_table_rows, table_row_count,
     &      row_time_s, row_p_pu, row_q_pu, system_mva, log_unit)
         table_read_done = .TRUE.
      ENDIF

! A load switched off has no bus to work on.
      bus_index = NUMLOD(load_index)
      IF (bus_index .LE. 0) RETURN

      CALL lpb1bl_base_demand(load_index, bus_index, bus_voltage_pu,
     &   static_demand_pu)
      static_p_pu = REAL(static_demand_pu)
      static_q_pu = AIMAG(static_demand_pu)
      target_p_pu = static_p_pu
      target_q_pu = static_q_pu

      time_now_s = TIME
      table_in_control = table_row_count .GT. 0
      IF (table_in_control) THEN
         table_in_control = time_now_s .GE. row_time_s(1)
     &      .AND. time_now_s .GT. mode1_time_s
      ENDIF

      IF (table_in_control) THEN
         first_con = LDSTRT(1,shared_slot)
         first_var = LDSTR2(2,private_slot)
         tfp_s = CON(first_con)
         tfq_s = CON(first_con+1)
         time_step_s = DELT
         CALL lpb1bl_table_lookup(time_now_s, table_row_count,
     &      row_time_s, row_p_pu, row_q_pu, table_segment,
     &      table_p_pu, table_q_pu)

! Keep track of the lag memories.  The first active call seeds them
! with the static demand; later calls only shift them when the clock
! has moved to a new instant, so repeated iterations at one instant
! always restart from the same stored output.
         previous_p_pu = VAR(first_var+var_prev_p)
         previous_q_pu = VAR(first_var+var_prev_q)
         lag_p_pu = VAR(first_var+var_lag_p)
         lag_q_pu = VAR(first_var+var_lag_q)
         prev_time_s = VAR(first_var+var_prev_time)
         this_time_s = VAR(first_var+var_this_time)
         IF (this_time_s .LT. 0.1*not_started) THEN
            previous_p_pu = static_p_pu
            previous_q_pu = static_q_pu
            prev_time_s = time_now_s - time_step_s
            this_time_s = time_now_s
         ELSE IF (time_now_s - this_time_s .GT. 0.5*time_step_s) THEN
            previous_p_pu = lag_p_pu
            previous_q_pu = lag_q_pu
            prev_time_s = this_time_s
            this_time_s = time_now_s
         ENDIF
         lag_step_s = this_time_s - prev_time_s
         lag_bypass_s = 4.0*time_step_s

! Below PQBRAK the played demand is scaled exactly like PSS/E scales
! a constant-power load.  The scaling acts after the lag.
         low_voltage_factor = 1.0
         IF (bus_voltage_pu .LT. PQBRAK)
     &      low_voltage_factor = CNSTPQ(bus_voltage_pu)

         IF (use_table_p .EQ. 1) THEN
            lag_p_pu = lpb1bl_lag_output(table_p_pu, previous_p_pu,
     &         lag_step_s, tfp_s, lag_bypass_s)
            target_p_pu = lag_p_pu*low_voltage_factor
         ELSE
            lag_p_pu = static_p_pu
         ENDIF

         IF (use_table_q .EQ. 1) THEN
            lag_q_pu = lpb1bl_lag_output(table_q_pu, previous_q_pu,
     &         lag_step_s, tfq_s, lag_bypass_s)
            target_q_pu = lag_q_pu*low_voltage_factor
         ELSE
            lag_q_pu = static_q_pu
         ENDIF

! Store the lag memories for the next call.
         VAR(first_var+var_prev_p) = previous_p_pu
         VAR(first_var+var_prev_q) = previous_q_pu
         VAR(first_var+var_lag_p) = lag_p_pu
         VAR(first_var+var_lag_q) = lag_q_pu
         VAR(first_var+var_prev_time) = prev_time_s
         VAR(first_var+var_this_time) = this_time_s
      ENDIF
      target_demand_pu = CMPLX(target_p_pu, target_q_pu)

! Expose the demand in force to PSS/E load channels and reports.
      TPLOAD(load_index) = target_p_pu
      TQLOAD(load_index) = target_q_pu

! Consumption is positive, so the extra demand is injected as the
! negative conjugate of the power gap divided by the bus voltage.
! A bus that is practically dead gets nothing.
      IF (bus_voltage_pu .GT. 1.0E-6) THEN
         bus_voltage_phasor = VOLT(bus_index)
         bus_current_pu = CURNT(bus_index)
         bus_current_pu = bus_current_pu
     &      - CONJG((target_demand_pu - static_demand_pu)
     &      /bus_voltage_phasor)
         CURNT(bus_index) = bus_current_pu
      ENDIF
      RETURN

      END SUBROUTINE LPB1BL

!=======================================================================
! lpb1bl_base_demand
!
! Rebuilds the static demand that SITER has already put on the bus at
! the present voltage: constant power (reduced below PQBRAK), constant
! current (reduced below 0.5 pu) and constant admittance.
!=======================================================================
      SUBROUTINE lpb1bl_base_demand(load_index, bus_index,
     &   bus_voltage_pu, static_demand_pu)
      INCLUDE 'COMON4.INS'

      INTEGER load_index           ! PSS/E load index (in)
      INTEGER bus_index            ! internal bus index of the load (in)
      REAL bus_voltage_pu          ! bus voltage magnitude (out)
      COMPLEX static_demand_pu     ! static P + jQ on system base (out)
      COMPLEX bus_voltage_phasor   ! VOLT: complex voltage of the bus
      COMPLEX nominal_power_pu     ! CLODFR row 1: constant power
      COMPLEX nominal_current_pu   ! CLODFR row 2: constant current
      COMPLEX nominal_admit_pu     ! CLODFR row 3: constant admittance
      COMPLEX current_part_pu      ! constant-current part of the load

      bus_voltage_phasor = VOLT(bus_index)
      nominal_power_pu = CLODFR(1,load_index)
      nominal_current_pu = CLODFR(2,load_index)
      nominal_admit_pu = CLODFR(3,load_index)
      bus_voltage_pu = ABS(bus_voltage_phasor)

! Constant-power part.
      static_demand_pu = nominal_power_pu
      IF (bus_voltage_pu .LT. PQBRAK) static_demand_pu =
     &   static_demand_pu*CNSTPQ(bus_voltage_pu)

! Constant-current part, proportional to the voltage.
      current_part_pu = bus_voltage_pu*nominal_current_pu
      IF (bus_voltage_pu .LT. 0.5) current_part_pu =
     &   current_part_pu*CNSTCR(bus_voltage_pu)

! Constant-admittance part, proportional to V squared.
      static_demand_pu = static_demand_pu + current_part_pu
     &   + bus_voltage_pu*bus_voltage_pu*CONJG(nominal_admit_pu)
      RETURN
      END SUBROUTINE lpb1bl_base_demand

!=======================================================================
! lpb1bl_lag_output
!
! One step of a first-order lag, solved exactly for an input that is
! held at its new value across the step.
!=======================================================================
      REAL FUNCTION lpb1bl_lag_output(target_value, previous_output,
     &   step_s, time_constant_s, bypass_limit_s)
      REAL target_value            ! input the lag is moving towards
      REAL previous_output         ! lag output at the preceding instant
      REAL step_s                  ! time elapsed since that instant [s]
      REAL time_constant_s         ! lag time constant [s]
      REAL bypass_limit_s          ! shorter constants skip the lag [s]

      IF (time_constant_s .LT. bypass_limit_s) THEN
         lpb1bl_lag_output = target_value
      ELSE IF (step_s .LE. 0.0) THEN
         lpb1bl_lag_output = previous_output
      ELSE
         lpb1bl_lag_output = target_value
     &      + (previous_output - target_value)
     &      *EXP(-step_s/time_constant_s)
      ENDIF
      RETURN
      END FUNCTION lpb1bl_lag_output

!=======================================================================
! lpb1bl_table_fetch
!
! Loads the demand table, converts MW and Mvar to system per unit and
! reports the outcome on message_unit.  Nothing is read when neither
! component is driven by the table.
!
! Rejection codes: 1 file missing or locked, 2 no data rows, 3 more
! rows than max_rows, 4 row that cannot be parsed, 5 instant not
! larger than the one before.
!=======================================================================
      SUBROUTINE lpb1bl_table_fetch(table_name, use_table_p,
     &   use_table_q, max_rows, row_count, row_time_s, row_p_pu,
     &   row_q_pu, system_mva, message_unit)
      CHARACTER*(*) table_name     ! table name without .lpb (in)
      INTEGER use_table_p          ! 1 when P comes from the table (in)
      INTEGER use_table_q          ! 1 when Q comes from the table (in)
      INTEGER max_rows             ! capacity of the row arrays (in)
      INTEGER row_count            ! rows accepted; 0 if unusable (out)
      REAL row_time_s(max_rows)    ! instant of each row [s] (out)
      REAL row_p_pu(max_rows)      ! active demand of each row (out)
      REAL row_q_pu(max_rows)      ! reactive demand of each row (out)
      REAL system_mva              ! system MVA base, SBASE (in)
      INTEGER message_unit         ! Fortran unit for messages (in)

      CHARACTER*260 file_name      ! table_name plus .lpb
      CHARACTER*512 line_text      ! one line of the table file
      INTEGER file_unit            ! unit opened on the table file
      INTEGER io_status            ! IOSTAT of the last OPEN or READ
      INTEGER reject_code          ! 0 when accepted, else see above
      INTEGER char_pos             ! character scanned in line_text
      REAL time_s, p_mw, q_mvar    ! values read from one row

      row_count = 0
      IF (use_table_p .NE. 1 .AND. use_table_q .NE. 1) RETURN

      file_name = TRIM(table_name)//'.lpb'
      reject_code = 0
      OPEN(NEWUNIT=file_unit, FILE=TRIM(file_name), STATUS='OLD',
     &   ACTION='READ', IOSTAT=io_status)
      IF (io_status .NE. 0) THEN
         reject_code = 1
      ELSE
         DO
            READ(file_unit, '(A)', IOSTAT=io_status) line_text
            IF (io_status .LT. 0) EXIT
            IF (io_status .GT. 0) THEN
               reject_code = 4
               EXIT
            ENDIF
            IF (LEN_TRIM(line_text) .EQ. 0) CYCLE

! Turn commas and tabs into blanks so one list-directed read copes
! with every accepted separator.
            DO char_pos = 1, LEN_TRIM(line_text)
               IF (line_text(char_pos:char_pos) .EQ. ',' .OR.
     &             line_text(char_pos:char_pos) .EQ. CHAR(9))
     &            line_text(char_pos:char_pos) = ' '
            END DO
            READ(line_text, *, IOSTAT=io_status) time_s, p_mw, q_mvar
            IF (io_status .NE. 0) THEN
               reject_code = 4
               EXIT
            ENDIF
            IF (row_count .GE. max_rows) THEN
               reject_code = 3
               EXIT
            ENDIF
            IF (row_count .GT. 0) THEN
               IF (time_s .LE. row_time_s(row_count)) THEN
                  reject_code = 5
                  EXIT
               ENDIF
            ENDIF
            row_count = row_count + 1
            row_time_s(row_count) = time_s
            row_p_pu(row_count) = p_mw/system_mva
            row_q_pu(row_count) = q_mvar/system_mva
         END DO
         CLOSE(file_unit)
         IF (reject_code .EQ. 0 .AND. row_count .EQ. 0) reject_code = 2
      ENDIF

! An unusable table leaves row_count at zero, which keeps the static
! load.
      IF (reject_code .NE. 0) THEN
         row_count = 0
         WRITE(message_unit, 9100) TRIM(file_name), reject_code
      ELSE
         WRITE(message_unit, 9110) row_count, TRIM(file_name)
      ENDIF
      RETURN

 9100 FORMAT(1X,'LPB1BL: table ',A,' rejected (code ',I1,
     &   '); the static load stays in force.')
 9110 FORMAT(1X,'LPB1BL: ',I7,' rows taken from ',A,'.')
      END SUBROUTINE lpb1bl_table_fetch

!=======================================================================
! lpb1bl_table_lookup
!
! Table demand at instant time_now_s.  Instants up to the first row
! return the first row, instants from the last row onwards return the
! last row, and anything in between is ramped linearly.  segment
! remembers the segment used last time, so a clock that only moves
! forward rarely needs more than one comparison.
!=======================================================================
      SUBROUTINE lpb1bl_table_lookup(time_now_s, row_count, row_time_s,
     &   row_p_pu, row_q_pu, segment, p_now_pu, q_now_pu)
      INTEGER row_count            ! rows in the table (in)
      INTEGER segment              ! first row of the segment (in/out)
      REAL time_now_s              ! instant to evaluate [s] (in)
      REAL row_time_s(row_count)   ! instant of each row [s] (in)
      REAL row_p_pu(row_count)     ! active demand of each row (in)
      REAL row_q_pu(row_count)     ! reactive demand of each row (in)
      REAL p_now_pu                ! active demand at time_now_s (out)
      REAL q_now_pu                ! reactive demand at time_now_s (out)
      REAL ramp_fraction           ! position inside the segment, 0..1

      IF (row_count .EQ. 1 .OR. time_now_s .LE. row_time_s(1)) THEN
         segment = 1
         p_now_pu = row_p_pu(1)
         q_now_pu = row_q_pu(1)
         RETURN
      ENDIF
      IF (time_now_s .GE. row_time_s(row_count)) THEN
         segment = row_count - 1
         p_now_pu = row_p_pu(row_count)
         q_now_pu = row_q_pu(row_count)
         RETURN
      ENDIF

      segment = MAX(1, MIN(segment, row_count - 1))
      DO WHILE (segment .GT. 1 .AND.
     &   time_now_s .LT. row_time_s(segment))
         segment = segment - 1
      END DO
      DO WHILE (segment .LT. row_count - 1 .AND.
     &   time_now_s .GT. row_time_s(segment+1))
         segment = segment + 1
      END DO

      ramp_fraction = (time_now_s - row_time_s(segment))
     &   /(row_time_s(segment+1) - row_time_s(segment))
      p_now_pu = row_p_pu(segment)
     &   + ramp_fraction*(row_p_pu(segment+1) - row_p_pu(segment))
      q_now_pu = row_q_pu(segment)
     &   + ramp_fraction*(row_q_pu(segment+1) - row_q_pu(segment))
      RETURN
      END SUBROUTINE lpb1bl_table_lookup
