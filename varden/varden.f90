subroutine varden()

  use BoxLib
  use omp_module
  use f2kcli
  use list_box_module
  use mboxarray_module
  use layout_module
  use multifab_module
  use init_module
  use estdt_module
  use vort_module
  use advance_module
  use bc_module
  use bl_mem_stat_module
  use bl_timer_module
  use box_util_module
  use bl_IO_module
  use define_bc_module
  use fabio_module
  use plotfile_module
  use checkpoint_module
  use restart_module

  implicit none

  integer    :: narg, farg
  integer    :: max_step,init_iter
  integer    :: plot_int, chk_int
  integer    :: verbose, mg_verbose
  integer    :: dm
  real(dp_t) :: cflfac
  real(dp_t) :: visc_coef
  real(dp_t) :: diff_coef
  real(dp_t) :: stop_time
  real(dp_t) :: time,dt,dtold,dt_hold,dt_temp
  integer    :: bcx_lo,bcx_hi,bcy_lo,bcy_hi,bcz_lo,bcz_hi
  integer    :: istep,ng_cell,ng_edge
  integer    :: i, n, nlevs, n_plot_comps, n_chk_comps, nscal
  integer    :: last_plt_written, last_chk_written
  integer    :: init_step
  integer    :: iunit

  real(dp_t) :: prob_hi_x,prob_hi_y,prob_hi_z

  integer     , allocatable :: domain_phys_bc(:,:)
  integer     , allocatable :: domain_press_bc(:,:)
  integer     , allocatable :: domain_norm_vel_bc(:,:)
  integer     , allocatable :: domain_tang_vel_bc(:,:)
  integer     , allocatable :: domain_scal_bc(:,:)
  integer     , pointer     :: rrs(:)
  integer     , allocatable :: ref_ratio(:)
  real(dp_t)  , pointer     :: dx(:,:)
  real(dp_t)  , allocatable :: prob_hi(:)
  type(layout), pointer     :: la_tower(:)

  type(multifab) :: umac, uedgex, uedgey, uedgez, utrans
  type(multifab) :: sedgex, sedgey, sedgez
  type(multifab), pointer ::       uold(:) => Null()
  type(multifab), pointer ::       sold(:) => Null()
  type(multifab), pointer ::         gp(:) => Null()
  type(multifab), pointer ::       unew(:) => Null()
  type(multifab), pointer ::       snew(:) => Null()
  type(multifab), pointer ::    rhohalf(:) => Null()
  type(multifab), pointer ::          p(:) => Null()
  type(multifab), pointer ::       vort(:) => Null()
  type(multifab), pointer ::      force(:) => Null()
  type(multifab), pointer :: scal_force(:) => Null()
  type(multifab), pointer ::   plotdata(:) => Null()
  type(multifab), pointer ::    chkdata(:) => Null()

  real(kind=dp_t), pointer :: uop(:,:,:,:)
  real(kind=dp_t), pointer :: sop(:,:,:,:)
  integer,allocatable      :: lo(:),hi(:)

  character(len=128) :: fname
  character(len=128) :: probin_env
  character(len=128) :: test_set
  character(len=7) :: sd_name
  character(len=20), allocatable :: plot_names(:)
  integer :: un, ierr
  integer :: restart
  logical :: lexist
  logical :: need_inputs
  logical :: nodal(3)

  type(layout)    :: la
  type(box)       :: domain_box
  type(mboxarray) :: mba

  type(bc_tower) ::  phys_bc_tower
  type(bc_tower) :: press_bc_tower
  type(bc_tower) ::  norm_bc_tower
  type(bc_tower) ::  tang_bc_tower
  type(bc_tower) ::  scal_bc_tower

  type(bc_level) ::  phys_bc

  namelist /probin/ stop_time
  namelist /probin/ prob_hi_x
  namelist /probin/ prob_hi_y
  namelist /probin/ prob_hi_z
  namelist /probin/ max_step
  namelist /probin/ plot_int
  namelist /probin/ chk_int
  namelist /probin/ init_iter
  namelist /probin/ cflfac
  namelist /probin/ visc_coef
  namelist /probin/ diff_coef
  namelist /probin/ test_set
  namelist /probin/ restart
  namelist /probin/ bcx_lo
  namelist /probin/ bcx_hi
  namelist /probin/ bcy_lo
  namelist /probin/ bcy_hi
  namelist /probin/ bcz_lo
  namelist /probin/ bcz_hi
  namelist /probin/ verbose
  namelist /probin/ mg_verbose

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

  ng_edge = 2
  ng_cell = 3

  narg = command_argument_count()

! Defaults
  max_step  = 1
  init_iter = 4
  plot_int  = 0
  chk_int  = 0

  dm    = 2
  nscal = 2

  need_inputs = .TRUE.
  test_set = ''
  restart = -1
  last_plt_written = -1
  last_chk_written = -1

  bcx_lo = WALL
  bcy_lo = WALL
  bcz_lo = WALL
  bcx_hi = WALL
  bcy_hi = WALL
  bcz_hi = WALL

  call get_environment_variable('PROBIN', probin_env, status = ierr)
  if ( need_inputs .AND. ierr == 0 ) then
     un = unit_new()
     open(unit=un, file = probin_env, status = 'old', action = 'read')
     read(unit=un, nml = probin)
     close(unit=un)
     need_inputs = .FALSE.
  end if

  farg = 1
  if ( need_inputs .AND. narg >= 1 ) then
     call get_command_argument(farg, value = fname)
     inquire(file = fname, exist = lexist )
     if ( lexist ) then
        farg = farg + 1
        un = unit_new()
        open(unit=un, file = fname, status = 'old', action = 'read')
        read(unit=un, nml = probin)
        close(unit=un)
        need_inputs = .FALSE.
     end if
  end if

  inquire(file = 'inputs_varden', exist = lexist)
  if ( need_inputs .AND. lexist ) then
     un = unit_new()
     open(unit=un, file = 'inputs_varden', status = 'old', action = 'read')
     read(unit=un, nml = probin)
     close(unit=un)
     need_inputs = .FALSE.
  end if

  if ( .true. ) then
     do while ( farg <= narg )
        call get_command_argument(farg, value = fname)
        select case (fname)

        case ('--prob_hi_x')
           farg = farg + 1
           call get_command_argument(farg, value = fname)
           read(fname, *) prob_hi_x

        case ('--prob_hi_y')
           farg = farg + 1
           call get_command_argument(farg, value = fname)
           read(fname, *) prob_hi_y

        case ('--prob_hi_z')
           farg = farg + 1
           call get_command_argument(farg, value = fname)
           read(fname, *) prob_hi_z

        case ('--cfl')
           farg = farg + 1
           call get_command_argument(farg, value = fname)
           read(fname, *) cflfac

        case ('--visc_coef')
           farg = farg + 1
           call get_command_argument(farg, value = fname)
           read(fname, *) visc_coef

        case ('--diff_coef')
           farg = farg + 1
           call get_command_argument(farg, value = fname)
           read(fname, *) diff_coef

        case ('--stop_time')
           farg = farg + 1
           call get_command_argument(farg, value = fname)
           read(fname, *) stop_time

        case ('--max_step')
           farg = farg + 1
           call get_command_argument(farg, value = fname)
           read(fname, *) max_step

        case ('--plot_int')
           farg = farg + 1
           call get_command_argument(farg, value = fname)
           read(fname, *) plot_int

        case ('--chk_int')
           farg = farg + 1
           call get_command_argument(farg, value = fname)
           read(fname, *) chk_int

        case ('--init_iter')
           farg = farg + 1
           call get_command_argument(farg, value = fname)
           read(fname, *) init_iter

        case ('--bcx_lo')
           farg = farg + 1
           call get_command_argument(farg, value = fname)
           read(fname, *) bcx_lo
        case ('--bcy_lo')
           farg = farg + 1
           call get_command_argument(farg, value = fname)
           read(fname, *) bcy_lo
        case ('--bcz_lo')
           farg = farg + 1
           call get_command_argument(farg, value = fname)
           read(fname, *) bcz_lo
        case ('--bcx_hi')
           farg = farg + 1
           call get_command_argument(farg, value = fname)
           read(fname, *) bcx_hi
        case ('--bcy_hi')
           farg = farg + 1
           call get_command_argument(farg, value = fname)
           read(fname, *) bcy_hi
        case ('--bcz_hi')
           farg = farg + 1
           call get_command_argument(farg, value = fname)
           read(fname, *) bcz_hi

        case ('--verbose')
           farg = farg + 1
           call get_command_argument(farg, value = fname)
           read(fname, *) verbose

        case ('--mg_verbose')
           farg = farg + 1
           call get_command_argument(farg, value = fname)
           read(fname, *) mg_verbose

        case ('--test_set')
           farg = farg + 1
           call get_command_argument(farg, value = test_set)

        case ('--restart')
           farg = farg + 1
           call get_command_argument(farg, value = fname)
           read(fname, *) restart

        case ('--')
           farg = farg + 1
           exit

        case default
           if ( .not. parallel_q() ) then
              write(*,*) 'UNKNOWN option = ', fname
              call bl_error("MAIN")
           end if
        end select

        farg = farg + 1
     end do
  end if

  allocate(prob_hi(dm))

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
! Set up plot_names for writing plot files.
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

  allocate(plot_names(2*dm+nscal+1))

  plot_names(1) = "x_vel"
  plot_names(2) = "y_vel"
  if (dm > 2) plot_names(3) = "z_vel"
  plot_names(dm+1) = "density"
  if (nscal > 1) plot_names(dm+2) = "tracer"
  plot_names(dm+nscal+1) = "vort"
  plot_names(dm+nscal+2) = "gpx"
  plot_names(dm+nscal+3) = "gpy"
  if (dm > 2) plot_names(dm+nscal+4) = "gpz"

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
! Initialize the arrays and read the restart data if restart >= 0
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

  if (restart >= 0) then

     call do_restart(dm,nscal,ng_cell,restart,la_tower,uold,sold,gp,p,rrs,dx,time,dt)
     nlevs = size(uold)
     domain_box = bbox(get_boxarray(la_tower(1)))

  else

     call read_a_hgproj_grid(mba, test_set)
     if (mba%dim .ne. dm) then
       print *,'BOXARRAY DIM NOT CONSISTENT WITH SPECIFIED DIM '
       stop
     end if
     nlevs = mba%nlevel
     allocate(la_tower(nlevs))
     call build(la_tower(1), mba%bas(1))
     allocate(ref_ratio(dm))
     do n = 2, nlevs
        ref_ratio = mba%rr(n-1,:)
        call layout_build_pn(la_tower(n), la_tower(n-1), mba%bas(n), ref_ratio)
     end do
     allocate(dx(nlevs,dm))

     allocate(uold(nlevs),sold(nlevs),p(nlevs),gp(nlevs))
     do n = 1,nlevs
        call multifab_build(   uold(n), la_tower(n),    dm, ng_cell)
        call multifab_build(   sold(n), la_tower(n),    dm, ng_cell)
        call multifab_build(     gp(n), la_tower(n),    dm,       1)
        call multifab_build(      p(n), la_tower(n),     1,       1, nodal)
        call setval(uold(n),0.0_dp_t, all=.true.)
        call setval(sold(n),0.0_dp_t, all=.true.)
        call setval(  gp(n),0.0_dp_t, all=.true.)
        call setval(   p(n),0.0_dp_t, all=.true.)
     end do
  end if

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
! Initialize all remaining arrays
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

  allocate(unew(nlevs),snew(nlevs))
  allocate(rhohalf(nlevs),vort(nlevs))
  allocate(force(nlevs),scal_force(nlevs))

  nodal = .true.

  do n = nlevs,1,-1
     call multifab_build(   unew(n), la_tower(n),    dm, ng_cell)
     call multifab_build(   snew(n), la_tower(n), nscal, ng_cell)

     call multifab_build(scal_force(n), la_tower(n), nscal, 1)
     call multifab_build(     force(n), la_tower(n),    dm, 1)
     call multifab_build(   rhohalf(n), la_tower(n),     1, 1)
     call multifab_build(      vort(n), la_tower(n),     1, 0)

     call setval(unew(n),0.0_dp_t, all=.true.)
     call setval(snew(n),0.0_dp_t, all=.true.)

     call setval(      vort(n),0.0_dp_t, all=.true.)
     call setval(   rhohalf(n),1.0_dp_t, all=.true.)
     call setval(     force(n),0.0_dp_t, all=.true.)
     call setval(scal_force(n),0.0_dp_t, all=.true.)
  end do

  la = la_tower(1)

  call multifab_build(umac       , la,    dm, ng_edge)
  call multifab_build(utrans     , la,    dm, ng_edge)

  call multifab_build(uedgex     , la,    dm, 1)
  call multifab_build(uedgey     , la,    dm, 1)
  call multifab_build(uedgez     , la,    dm, 1)
  call multifab_build(sedgex     , la, nscal, 1)
  call multifab_build(sedgey     , la, nscal, 1)
  call multifab_build(sedgez     , la, nscal, 1)

  call setval(umac,0.0_dp_t, all=.true.)

  prob_hi(1) = prob_hi_x
  if (dm > 1) prob_hi(2) = prob_hi_y
  if (dm > 2) prob_hi(3) = prob_hi_z

  if (restart < 0) then
!    Define dx at the base level, then at refined levels.
     domain_box = mba%pd(1)
     do i = 1,dm
       dx(1,i) = prob_hi(i) / float(domain_box%hi(i)-domain_box%lo(i)+1)
     end do
     do n = 2,nlevs
       dx(n,:) = dx(n-1,:) / mba%rr(n-1,:)
     end do

     allocate(rrs(nlevs-1))
     if (nlevs > 1) rrs = 2
  end if

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
! Allocate the arrays for the boundary conditions at the physical boundaries.
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

  allocate(domain_phys_bc(dm,2))
  allocate(domain_press_bc(dm,2))
  allocate(domain_norm_vel_bc(dm,2))
  allocate(domain_tang_vel_bc(dm,2))
  allocate(domain_scal_bc(dm,2))

! Put the bc values from the inputs file into domain_phys_bc
  domain_phys_bc(1,1) = bcx_lo
  domain_phys_bc(1,2) = bcx_hi
  if (dm > 1) then
     domain_phys_bc(2,1) = bcy_lo
     domain_phys_bc(2,2) = bcy_hi
  end if
  if (dm > 2) then
     domain_phys_bc(3,1) = bcz_lo
     domain_phys_bc(3,2) = bcz_hi
  end if

! Translate the domain_phys_bc values into domain_bc's for each component
  call define_bcs(domain_phys_bc,domain_norm_vel_bc,domain_tang_vel_bc, &
                  domain_scal_bc,domain_press_bc,visc_coef)

! Build the arrays for each grid from the domain_bc arrays.
  call bc_tower_build( phys_bc_tower,la_tower,domain_phys_bc,INTERIOR)
  call bc_tower_build(press_bc_tower,la_tower,domain_press_bc,BC_INT)
  call bc_tower_build( norm_bc_tower,la_tower,domain_norm_vel_bc,BC_INT)
  call bc_tower_build( tang_bc_tower,la_tower,domain_tang_vel_bc,BC_INT)
  call bc_tower_build( scal_bc_tower,la_tower,domain_scal_bc,BC_INT)

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
! Now initialize the grid data, and do initial projection if restart < 0.
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

  if (restart < 0) then
     time    = 0.0_dp_t
     dt      = 1.d20
     dt_temp = 1.0_dp_t
     do n = 1,nlevs

        call initdata(uold(n),sold(n),dx(n,:),prob_hi, &
                      phys_bc_tower%bc_tower_array(n),visc_coef)

!       Note that we use rhohalf, filled with 1 at this point, as a temporary
!          in order to do a constant-density initial projection.
        call hgproject(uold(n),rhohalf(n),p(n),gp(n),dx(n,:),dt_temp, &
                       phys_bc_tower%bc_tower_array(n),domain_press_bc, verbose, mg_verbose)
     end do

     do n = 1,nlevs
        call setval(gp(n)  ,0.0_dp_t, all=.true.)
     end do

  endif

  allocate(lo(dm),hi(dm))
  do n = 1,nlevs
     phys_bc = phys_bc_tower%bc_tower_array(n)
     do i = 1, uold(n)%nboxes
       if ( multifab_remote(uold(n), i) ) cycle
       uop => dataptr(uold(n), i)
       sop => dataptr(sold(n), i)
       lo =  lwb(get_box(uold(n), i))
       hi =  upb(get_box(uold(n), i))
       select case (dm)
          case (2)
            call setvelbc_2d(uop(:,:,1,:), lo, ng_cell, &
                             phys_bc%bc_level_array(i,:,:),visc_coef)
            call setscalbc_2d(sop(:,:,1,:), lo, ng_cell, &
                              phys_bc%bc_level_array(i,:,:))
         end select
     end do

     call multifab_fill_boundary(uold(n))
     call multifab_fill_boundary(sold(n))

!    This is done to impose any Dirichlet bc's on unew or snew.
     call multifab_copy_c(unew(n),1,uold(n),1,dm   ,all=.true.)
     call multifab_copy_c(snew(n),1,sold(n),1,nscal,all=.true.)

  end do

  dtold = dt

  do n = 1,nlevs
     dt_hold = dt
     call estdt(uold(n),sold(n),dx(n,:),cflfac,dtold,dt)
     dt = min(dt_hold,dt)
  end do

  allocate(plotdata(nlevs))
  n_plot_comps = 2*dm + nscal + 1
  do n = 1,nlevs
     call multifab_build(plotdata(n), la_tower(n), n_plot_comps, 0)
  end do

  allocate(chkdata(nlevs))
  n_chk_comps = 2*dm + nscal
  do n = 1,nlevs
     call multifab_build(chkdata(n), la_tower(n), n_chk_comps, 0)
  end do

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
! Begin the initial iterations to define an initial pressure field.
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

  if (restart < 0 .and. init_iter > 0) then
     if (verbose .eq. 1) print *,'DOING ',init_iter,' INITIAL ITERATIONS ' 
     do istep = 1,init_iter
      do n = 1,nlevs
         call advance(uold(n),unew(n),sold(n),snew(n),rhohalf(n),&
                      umac,uedgex,uedgey,uedgez, &
                      sedgex,sedgey,sedgez, &
                      utrans,gp(n),p(n),force(n),scal_force(n),&
                      dx(n,:),time,dt, &
                      phys_bc_tower%bc_tower_array(n), &
                      norm_bc_tower%bc_tower_array(n), &
                      tang_bc_tower%bc_tower_array(n), &
                      scal_bc_tower%bc_tower_array(n), &
                      press_bc_tower%bc_tower_array(n), &
                      domain_press_bc, domain_norm_vel_bc, domain_scal_bc, &
                      visc_coef,diff_coef,verbose,mg_verbose)
      end do
      if (verbose .eq. 1) then
         do n = 1,nlevs
            print *,'MAX OF UOLD ',norm_inf(uold(n)),' AT LEVEL ',n
            print *,'MAX OF UNEW ',norm_inf(unew(n)),' AT LEVEL ',n
         end do
         print *,' '
      end if
     end do

     do n = 1,nlevs
        call make_vorticity(vort(n),uold(n),dx(n,:), &
                            phys_bc_tower%bc_tower_array(n))
     end do

!    This writes a plotfile.
     istep = 0
     do n = 1,nlevs
        call multifab_copy_c(plotdata(n),1           ,uold(n),1,dm)
        call multifab_copy_c(plotdata(n),1+dm        ,sold(n),1,nscal)
        call multifab_copy_c(plotdata(n),1+dm+nscal  ,vort(n),1,1)
        call multifab_copy_c(plotdata(n),1+dm+nscal+1,  gp(n),1,dm)
     end do
     write(unit=sd_name,fmt='("plt",i4.4)') istep
     call fabio_ml_multifab_write_d(plotdata, rrs, sd_name, plot_names, &
                                  domain_box, time, dx(1,:))
     last_plt_written = istep

!    This writes a checkpoint file.

     do n = 1,nlevs
        call multifab_copy_c(chkdata(n),1         ,uold(n),1,dm)
        call multifab_copy_c(chkdata(n),1+dm      ,sold(n),1,nscal)
        call multifab_copy_c(chkdata(n),1+dm+nscal,  gp(n),1,dm)
     end do
     write(unit=sd_name,fmt='("chk",i4.4)') istep

     call checkpoint_write(sd_name, chkdata, p, rrs, dx, time, dt)
     last_chk_written = istep

  end if

  if (restart < 0) then
     init_step = 1
  else
     init_step = restart+1
  end if

  if (max_step >= init_step) then
     if (verbose .eq. 1) print *,'DOING TIME ADVANCE WITH DT = ',dt

       do istep = init_step,max_step

       do n = 1,nlevs
          call multifab_fill_boundary(uold(n))
          call multifab_fill_boundary(sold(n))

          dtold = dt
          call estdt(uold(n),sold(n),dx(n,:),cflfac,dtold,dt)

          if (verbose .eq. 1) print *,'MAX OF UOLD ',norm_inf(uold(n)),' AT TIME ',time

          call advance(uold(n),unew(n),sold(n),snew(n),rhohalf(n), &
                       umac,uedgex,uedgey,uedgez, &
                       sedgex,sedgey,sedgez, &
                       utrans,gp(n),p(n),force(n),scal_force(n),&
                       dx(n,:),time,dt, &
                       phys_bc_tower%bc_tower_array(n), &
                       norm_bc_tower%bc_tower_array(n), &
                       tang_bc_tower%bc_tower_array(n), &
                       scal_bc_tower%bc_tower_array(n), &
                       press_bc_tower%bc_tower_array(n), &
                       domain_press_bc, domain_norm_vel_bc, domain_scal_bc, &
                       visc_coef,diff_coef,verbose,mg_verbose)

          time = time + dt

          write(6,1000) istep,time,dt

         end do

         do n = 1,nlevs
           call multifab_copy_c(uold(n),1,unew(n),1,dm)
           call multifab_copy_c(sold(n),1,snew(n),1,nscal)
         end do

         if (plot_int > 0 .and. mod(istep,plot_int) .eq. 0) then
            do n = 1,nlevs
               call make_vorticity(vort(n),uold(n),dx(n,:), &
                                   phys_bc_tower%bc_tower_array(n))
               call multifab_copy_c(plotdata(n),1           ,unew(n),1,dm)
               call multifab_copy_c(plotdata(n),1+dm        ,snew(n),1,nscal)
               call multifab_copy_c(plotdata(n),1+dm+nscal  ,vort(n),1,1)
               call multifab_copy_c(plotdata(n),1+dm+nscal+1,  gp(n),1,dm)
            end do
            write(unit=sd_name,fmt='("plt",i4.4)') istep
            call fabio_ml_multifab_write_d(plotdata, rrs, sd_name, plot_names, &
                                           domain_box, time, dx(1,:))
            last_plt_written = istep
         end if

         if (chk_int > 0 .and. mod(istep,chk_int) .eq. 0) then
            do n = 1,nlevs
               call multifab_copy_c(chkdata(n),1         ,unew(n),1,dm)
               call multifab_copy_c(chkdata(n),1+dm      ,snew(n),1,nscal)
               call multifab_copy_c(chkdata(n),1+dm+nscal,  gp(n),1,dm)
            end do
            write(unit=sd_name,fmt='("chk",i4.4)') istep
            call checkpoint_write(sd_name, chkdata, p, rrs, dx, time, dt)
            last_chk_written = istep
         end if

       end do

1000   format('STEP = ',i4,1x,' TIME = ',f14.10,1x,'DT = ',f14.9)

       if (last_plt_written .ne. max_step) then
!       This writes a plotfile.
        do n = 1,nlevs
          call make_vorticity(vort(n),uold(n),dx(n,:), &
                              phys_bc_tower%bc_tower_array(n))
          call multifab_copy_c(plotdata(n),1           ,unew(n),1,dm)
          call multifab_copy_c(plotdata(n),1+dm        ,snew(n),1,nscal)
          call multifab_copy_c(plotdata(n),1+dm+nscal  ,vort(n),1,1)
          call multifab_copy_c(plotdata(n),1+dm+nscal+1,  gp(n),1,dm)
        end do
        write(unit=sd_name,fmt='("plt",i4.4)') max_step
        call fabio_ml_multifab_write_d(plotdata, rrs, sd_name, plot_names, &
                                      domain_box, time, dx(1,:))
       end if

       if (last_chk_written .ne. max_step) then
!       This writes a checkpoint file.
        do n = 1,nlevs
          call multifab_copy_c(chkdata(n),1         ,unew(n),1,dm)
          call multifab_copy_c(chkdata(n),1+dm      ,snew(n),1,nscal)
          call multifab_copy_c(chkdata(n),1+dm+nscal,  gp(n),1,dm)
        end do
        write(unit=sd_name,fmt='("chk",i4.4)') max_step
        call checkpoint_write(sd_name, chkdata, p, rrs, dx, time, dt)
       end if

  end if

  do n = 1,nlevs
     call multifab_destroy(uold(n))
     call multifab_destroy(unew(n))
     call multifab_destroy(sold(n))
     call multifab_destroy(snew(n))
     call multifab_destroy( p(n))
     call multifab_destroy(gp(n))
     call multifab_destroy(rhohalf(n))
     call multifab_destroy(force(n))
     call multifab_destroy(scal_force(n))
     call multifab_destroy(plotdata(n))
     call multifab_destroy(chkdata(n))
  end do

  deallocate(domain_norm_vel_bc)
  deallocate(domain_tang_vel_bc)
  deallocate(domain_scal_bc)
  deallocate(domain_press_bc)
  deallocate(domain_phys_bc)

end subroutine varden
