!
! PIERNIK Code Copyright (C) 2006 Michal Hanasz
!
!    This file is part of PIERNIK code.
!
!    PIERNIK is free software: you can redistribute it and/or modify
!    it under the terms of the GNU General Public License as published by
!    the Free Software Foundation, either version 3 of the License, or
!    (at your option) any later version.
!
!    PIERNIK is distributed in the hope that it will be useful,
!    but WITHOUT ANY WARRANTY; without even the implied warranty of
!    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
!    GNU General Public License for more details.
!
!    You should have received a copy of the GNU General Public License
!    along with PIERNIK.  If not, see <http://www.gnu.org/licenses/>.
!
!    Initial implementation of PIERNIK code was based on TVD split MHD code by
!    Ue-Li Pen
!        see: Pen, Arras & Wong (2003) for algorithm and
!             http://www.cita.utoronto.ca/~pen/MHD
!             for original source code "mhd.f90"
!
!    For full list of developers see $PIERNIK_HOME/license/pdt.txt
!
#include "piernik.h"

module initpiernik

   implicit none
   private
   public :: init_piernik

contains
!>
!! Meta subroutine responsible for initializing all piernik modules
!! \deprecated remove the "__INTEL_COMPILER" clauses as soon as Intel Compiler gets required features and/or bug fixes
!! \todo move init_geometry call to init_domain or init_grid
!! \todo add checks against PIERNIK_INIT_IO_IC to all initproblem::read_problem_par
!! \todo split init_dataio
!<
   subroutine init_piernik

      use all_boundaries,        only: all_bnd
      use cg_level_finest,       only: finest
      use cg_list_global,        only: all_cg
      use constants,             only: PIERNIK_INIT_MPI, PIERNIK_INIT_GLOBAL, PIERNIK_INIT_FLUIDS, PIERNIK_INIT_DOMAIN, PIERNIK_INIT_GRID, PIERNIK_INIT_IO_IC, INCEPTIVE, tmr_fu
      use dataio,                only: init_dataio, init_dataio_parameters, write_data
      use dataio_pub,            only: nrestart, wd_rd, par_file, tmp_log_file, msg, printio, printinfo, warn, require_problem_IC, problem_name, run_id, code_progress, log_wr
      use decomposition,         only: init_decomposition
      use domain,                only: init_domain
      use diagnostics,           only: diagnose_arrays, check_environment
      use fargo,                 only: init_fargo
      use fluidboundaries_funcs, only: init_default_fluidboundaries
      use global,                only: init_global
      use grid,                  only: init_grid
      use grid_container_ext,    only: cg_extptrs
      use gridgeometry,          only: init_geometry
      use initfluids,            only: init_fluids, sanitize_smallx_checks
      use interactions,          only: init_interactions
      use initproblem,           only: problem_initial_conditions, read_problem_par, problem_pointers
      use mpisetup,              only: init_mpi, master
      use refinement,            only: init_refinement
      use refinement_flag,       only: level_max
      use refinement_update,     only: update_refinement
      use timer,                 only: set_timer
      use units,                 only: init_units
      use user_hooks,            only: problem_post_restart
#if defined MAGNETIC && defined RESISTIVE
      use resistivity,           only: init_resistivity, compute_resist
#endif /* MAGNETIC && RESISTIVE */
#ifdef SHEAR
      use shear,                 only: init_shear
#endif /* SHEAR */
#ifdef GRAV
      use gravity,               only: init_grav, init_grav_ext, manage_grav_pot_3d, sum_potential
      use hydrostatic,           only: init_hydrostatic, cleanup_hydrostatic
#endif /* GRAV */
#ifdef MULTIGRID
      use multigrid,             only: init_multigrid, init_multigrid_ext, multigrid_par
#endif /* MULTIGRID */
#ifdef SN_SRC
      use snsources,             only: init_snsources
#endif /* SN_SRC */
#ifdef DEBUG
      use piernikdebug,          only: init_piernikdebug
      use piernikiodebug,        only: init_piernikiodebug
#endif /* DEBUG */
#ifdef CORIOLIS
      use coriolis,              only: init_coriolis
#endif /* CORIOLIS */
#ifdef COSM_RAYS
      use crdiffusion,           only: init_crdiffusion
#endif /* COSM_RAYS */
#ifdef PIERNIK_OPENCL
      use piernikcl,             only: init_opencl
#endif /* PIERNIK_OPENCL */
#if defined(__INTEL_COMPILER)
      !> \deprecated remove this clause as soon as Intel Compiler gets required features and/or bug fixes
      use timestep,              only: init_time_step
#ifdef COSM_RAYS
      use crhelpers,             only: init_div_v
#endif /* COSM_RAYS */
#endif /* __INTEL_COMPILER */

      implicit none

      integer :: nit, ac
      logical :: finished
      integer, parameter :: nit_over = 5 ! maximum number of auxiliary iterations after reaching level_max

      call parse_cmdline
      write(par_file,'(2a)') trim(wd_rd),'problem.par'
      write(tmp_log_file,'(2a)') trim(log_wr),'tmp.log'

      call init_mpi                          ! First, we must initialize the communication (and things that do not depend on init_mpi if there are any)
      code_progress = PIERNIK_INIT_MPI       ! Now we can initialize grid and everything that depends at most on init_mpi. All calls prior to PIERNIK_INIT_GRID can be reshuffled when necessary
      call check_environment

#ifdef PIERNIK_OPENCL
      call init_opencl
#endif /* PIERNIK_OPENCL */

#ifdef DEBUG
      call init_piernikdebug                 ! Make it available as early as possible - right after init_mpi
      call init_piernikiodebug
#endif /* DEBUG */

      call cg_extptrs%epa_init

      call init_dataio_parameters            ! Required very early to call colormessage without side-effects

      call init_units

      call init_default_fluidboundaries

      call problem_pointers                  ! set up problem-specific pointers as early as possible to allow implementation of problem-specific hacks also during the initialization

      call init_global
      code_progress = PIERNIK_INIT_GLOBAL    ! Global parameters are set up

      call init_domain
      code_progress = PIERNIK_INIT_DOMAIN    ! Base domain is known and initial domain decomposition is known
      call init_geometry                     ! depends on domain

      call init_fluids
      code_progress = PIERNIK_INIT_FLUIDS    ! Fluid properties are set up

      call all_cg%register_fluids            ! Register named fields for u, b and wa, depends on fluids and domain
      call all_cg%init

#ifdef COSM_RAYS
#if defined(__INTEL_COMPILER)
      !> \deprecated remove this clause as soon as Intel Compiler gets required features and/or bug fixes
      call init_div_v
#endif /* __INTEL_COMPILER */
      call init_crdiffusion                  ! depends on fluids
#endif /* COSM_RAYS */

      call init_interactions                 ! requires flind and units

      call init_refinement

      call init_decomposition
#ifdef GRAV
      call init_grav                         ! Has to be called before init_grid
      call init_grav_ext
#endif /* GRAV */
#ifdef MULTIGRID
      call init_multigrid_ext                ! Has to be called before init_grid
      call multigrid_par
#endif /* MULTIGRID */

      call init_grid                         ! Most of the cg's vars are now initialized, only arrays left
      code_progress = PIERNIK_INIT_GRID      ! Now we can initialize things that depend on all the above fundamental calls

#ifdef SHEAR
      call init_shear                        ! depends on fluids
#endif /* SHEAR */

#ifdef RESISTIVE
      call init_resistivity                  ! depends on grid
#endif /* RESISTIVE */

#ifdef GRAV
      call manage_grav_pot_3d(.true.)        !> \deprecated It is only temporary solution, but grav_pot_3d must be called after problem_initial_conditions due to csim2,c_si,alpha clash!!!
      call init_hydrostatic
#endif /* GRAV */

#ifdef CORIOLIS
      call init_coriolis                     ! depends on geometry
#endif /* CORIOLIS */

#ifdef SN_SRC
      call init_snsources                    ! depends on grid and fluids/cosmicrays
#endif /* SN_SRC */

#ifdef MULTIGRID
      call init_multigrid                    ! depends on grid, geometry, units and arrays
#endif /* MULTIGRID */

#if defined(__INTEL_COMPILER)
      !> \deprecated remove this clause as soon as Intel Compiler gets required features and/or bug fixes
      call init_time_step
#endif /* __INTEL_COMPILER */

      call init_fargo

      code_progress = PIERNIK_INIT_IO_IC     ! Almost everything is initialized: do problem-related stuff here, set-up I/O and create or read the initial conditions.

      call read_problem_par                  ! may depend on anything but init_dataio, \todo add checks against PIERNIK_INIT_IO_IC to all initproblem::read_problem_par

      call init_dataio                       ! depends on units, fluids (through common_hdf5), fluidboundaries, arrays, grid and shear (through magboundaries::bnd_b or fluidboundaries::bnd_u) \todo split me
#if defined(GRAV) && !defined(SELF_GRAV)
      call sum_potential                     ! for the proper tsl&log data gpot array has to be fill in using gp array values after restart read
                                             !> \todo check and fulfil this requirement for SELF_GRAV defined (should source_terms_grav be called here?)
                                             !> \deprecated this probably should be guaranteed to be done elsewhere.
#endif /* GRAV && !SELF_GRAV */
      if (nrestart /= 0) call all_bnd

      if (master) then
         call printinfo("###############     Initial Conditions     ###############", .false.)
         write(msg,'(4a)') "   Starting problem : ",trim(problem_name)," :: ",trim(run_id)
         call printinfo(msg, .true.)
         call printinfo("", .true.)
      endif
      !>
      !! \deprecated It makes no sense to call (sometimes expensive) problem_initial_conditions before reading restart file.
      !! BEWARE: If your problem requires to call problem_initial_conditions add "require_problem_IC = 1" to restart file
      !! Move everything that is not regenerated by restart file to read_problem_par or create separate post-restart initialization
      !<
      !> \warning Set initial conditions by hand when starting from scratch or read them from a restart file. Do not use both unless you REALLY need to do so.
      if (nrestart > 0 .and. require_problem_IC /= 1) then
         if (master) then
            write(msg,'(a,i4,a)') "[initpiernik:init_piernik] Restart file #",nrestart," read. Skipping problem_initial_conditions."
            call printio(msg)
         endif
         if (associated(problem_post_restart)) then
            if (master) call printinfo("[initpiernik:init_piernik] Calling problem specific, post restart procedure")
            call problem_post_restart
         endif
      else

         nit = 0
         finished = .false.
         call problem_initial_conditions ! may depend on anything

         write(msg, '(a,f10.2)')"[initpiernik] IC on base level, time elapsed: ",set_timer(tmr_fu)
         if (master) call printinfo(msg)

         do while (.not. finished)

            call all_bnd !> \warning Never assume that problem_initial_conditions set guardcells correctly
#ifdef GRAV
            call manage_grav_pot_3d(.false., update_gp = (nit /= 0))
            call cleanup_hydrostatic
#endif /* GRAV */

            call update_refinement(act_count=ac)
            finished = (ac == 0) .or. (nit > 2*level_max + nit_over) ! level_max iterations for creating refinement levels + level_max iterations for derefining excess of blocks

            call problem_initial_conditions ! reset initial conditions after possible changes of refinement structure
            nit = nit + 1
            write(msg, '(2(a,i3),a,f10.2)')"[initpiernik] IC iteration: ",nit,", finest level:",finest%level%level_id,", time elapsed: ",set_timer(tmr_fu)
            if (master) call printinfo(msg)
         enddo

         if (ac /= 0 .and. master) call warn("[initpiernik:init_piernik] The refinement structure does not seem to converge. Your refinement criteria may lead to oscillations of refinement structure. Bailing out.")

      endif

      write(msg, '(a,3i8,a,i3)')"[initpiernik:init_piernik] Effective resolution is [", finest%level%n_d(:), " ] at level ", finest%level%level_id
      !> \todo Do an MPI_Reduce in case the master process don't have any part of the globally finest level or ensure it is empty in such case
      if (master) call printinfo(msg)

#ifdef RESISTIVE
      call compute_resist                    ! etamax%val is required by timestep_resist
#endif /* RESISTIVE */
#ifdef VERBOSE
      call diagnose_arrays                   ! may depend on everything
#endif /* VERBOSE */

      call write_data(output=INCEPTIVE)

      call sanitize_smallx_checks            ! depends on problem_initial_conditions || init_dataio/read_restart_hdf5

   end subroutine init_piernik
!-----------------------------------------------------------------------------
   subroutine parse_cmdline

      use constants,  only: stdout, cwdlen, INT4
      use dataio_pub, only: cmdl_nml, wd_rd, wd_wr, piernik_hdf5_version, log_wr
      use version,    only: nenv,env, init_version

      implicit none

      integer :: i, j
      logical :: skip_next
      character(len=8)            :: date   ! QA_WARN len defined by ISO standard
      character(len=10)           :: time   ! QA_WARN len defined by ISO standard
      character(len=5)            :: zone   ! QA_WARN len defined by ISO standard
      character(len=cwdlen)       :: arg
!      character(len=*), parameter :: cmdlversion = '1.0'
      logical, save               :: do_time = .false.
      integer(kind=4), dimension(:), allocatable :: revision
      character(len=cwdlen)       :: aaa

      skip_next = .false.

      do i = 1, command_argument_count()
         if (skip_next) then
            skip_next = .false.
            cycle
         endif
         call get_command_argument(i, arg)

         select case (arg)
         case ('-v', '--version')
!            print '(2a)', 'cmdline version ', cmdlversion
            call init_version
            allocate(revision(nenv)) ; revision = 0_INT4
            do j = 2, nenv
               read(env(j),'(a37,1x,i4)') aaa(1:37), revision(j)
            enddo
            write(stdout, '(a,i6)') 'code revision: ', maxval(revision)
            deallocate(revision)
            write(stdout, '(a,f5.2)') 'output version: ',piernik_hdf5_version
            write(stdout,'(a)') "###############     Source configuration     ###############"
            do j = 1, nenv
               write(stdout,'(a)') env(j)
            enddo
            stop
         case ('-p', '--param')
            call get_command_argument(i+1,arg)
            write(wd_rd,'(a)') arg
            skip_next = .true.
         case ('-w', '--write')
            call get_command_argument(i+1,arg)
            write(wd_wr,'(a)') arg
            skip_next = .true.
         case ('-l', '--log')
            call get_command_argument(i+1,arg)
            write(log_wr,'(a)') arg
            skip_next = .true.
         case ('-n', '--namelist')
            call get_command_argument(i+1,arg)
            write(cmdl_nml, '(3A)') cmdl_nml(1:len_trim(cmdl_nml)), " ", trim(arg)
            skip_next = .true.
         case ('-h', '--help')
            call print_help()
            stop
         case ('-t', '--time')
            do_time = .true.
         case default
            print '(a,a,/)', 'Unrecognized command-line option: ', arg
            call print_help()
            stop
         end select
      enddo

      if (wd_wr(len_trim(wd_wr):len_trim(wd_wr)) /= '/' ) write(wd_wr,'(a,a1)') trim(wd_wr),'/'
      if (wd_rd(len_trim(wd_rd):len_trim(wd_rd)) /= '/' ) write(wd_rd,'(a,a1)') trim(wd_rd),'/'

      ! Print the date and, optionally, the time
      call date_and_time(DATE=date, TIME=time, ZONE=zone)
      if (do_time) then
         write (stdout, '(a,"-",a,"-",a)', advance='no') date(1:4), date(5:6), date(7:8)
         write (stdout, '(1x,a,":",a,1x,a)') time(1:2), time(3:4), zone
         stop
      endif
   end subroutine parse_cmdline
!-----------------------------------------------------------------------------
   subroutine print_help

      use constants, only: cwdlen

      implicit none

      character(len=cwdlen) :: calledname

      call get_command_argument(0, calledname)

      print '(3a)','usage: ',trim(calledname),' [OPTIONS]'
      print '(a)', ''
      print '(a)', 'Recognized options:'
      print '(a)', ''
      print '(a)', '  -v, --version     print version information and exit'
      print '(6a)','  -n, --namelist    read namelist from command line, e.g. ',trim(calledname)," -n '",achar(38),'OUTPUT_CONTROL run_id="t22" /',"'"
      print '(a)', '  -p, --param       path to the directory with problem.par and/or restarts (default: ".")'
      print '(a)', '  -w, --write       path to the directory where output will be written (default: ".")'
      print '(a)', '  -l, --log         path to the directory where logs will be written (default: ".")'
      print '(a)', '  -h, --help        print usage information and exit'
      print '(a)', '  -t, --time        print time and exit'

   end subroutine print_help
!-----------------------------------------------------------------------------
end module initpiernik
