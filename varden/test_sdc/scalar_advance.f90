module scalar_advance_module

  use bl_types
  use multifab_module
  use ml_layout_module
  use define_bc_module
  use explicit_diffusive_module
  use viscous_module
  use macproject_module
  use probin_module, only : nscal, diff_coef, diffusion_type, stencil_order, &
                            verbose, mg_verbose, cg_verbose

  implicit none

  private

  public :: scalar_advance

contains

  subroutine scalar_advance(mla,uold,sold,snew,umac, &
                            ext_scal_force,aofs,dx,dt,the_bc_tower)

    use mkflux_module
    use mkforce_module
    use update_module
    use bl_constants_module

    type(ml_layout), intent(in   ) :: mla
    type(multifab) , intent(in   ) :: uold(:)
    type(multifab) , intent(in   ) :: sold(:)
    type(multifab) , intent(inout) :: snew(:)
    type(multifab) , intent(in   ) :: umac(:,:)
    type(multifab) , intent(in   ) :: ext_scal_force(:)
    type(multifab) , intent(inout) :: aofs(:)
    real(kind=dp_t), intent(in   ) :: dx(:,:),dt
    type(bc_tower) , intent(in   ) :: the_bc_tower

    ! local variables
    type(multifab), allocatable :: scal_force(:), divu(:), laps(:)
    type(multifab), allocatable :: sflux(:,:), sedge(:,:)
    logical       , allocatable :: is_conservative(:)
    logical       , allocatable :: umac_nodal_flag(:)

    integer         :: i,n
    integer         :: comp,bc_comp,nlevs,dm
    logical         :: is_vel
    real(kind=dp_t) :: diff_fac,visc_mu
    real(kind=dp_t) :: smin,smax

    nlevs = mla%nlevel
    dm    = mla%dim

    allocate(umac_nodal_flag(mla%dim))
    allocate(scal_force(nlevs),divu(nlevs),laps(nlevs))
    allocate(sflux(nlevs,dm),sedge(nlevs,dm))
    allocate(is_conservative(nscal))

    is_conservative(1) = .true.
    is_conservative(2) = .false.

    is_vel  = .false.

    do n = 1, nlevs
       call multifab_build( scal_force(n),ext_scal_force(n)%la,nscal,1)
       call multifab_build( divu(n),mla%la(n),    1,1)
       call multifab_build( laps(n),mla%la(n),nscal,0)
       do i = 1,dm
         umac_nodal_flag(:) = .false.
         umac_nodal_flag(i) = .true.
         call multifab_build(sflux(n,i),scal_force(n)%la,nscal,0,nodal = umac_nodal_flag)
         call multifab_build(sedge(n,i),scal_force(n)%la,nscal,0,nodal = umac_nodal_flag)
         call setval(sflux(n,i),ZERO,all=.true.)
         call setval(sedge(n,i),ZERO,all=.true.)
       end do

       call setval(scal_force(n),0.0_dp_t,all=.true.)
       call setval(divu(n),0.0_dp_t,all=.true.)
       call setval(laps(n),0.0_dp_t,all=.true.)
    enddo

    !***********************************
    ! Compute laps for passive scalar only
    !***********************************
    if (diff_coef .gt. ZERO .and. diffusion_type .eq. 1) then
       comp = 2
       bc_comp = dm+comp
       call get_explicit_diffusive_term(mla,laps,sold,comp,bc_comp,dx,the_bc_tower)
    else
      do n = 1, nlevs
         call setval(laps(n),ZERO)
      enddo
    endif

    !***********************************
    ! Create scalar force at time n.
    !***********************************

    diff_fac = ONE
    call mkscalforce(nlevs,scal_force,ext_scal_force,laps,diff_fac)

    !***********************************
    ! Create edge state scalars/fluxes
    !***********************************

    call mkflux(mla,sold,uold,sedge,sflux,umac,scal_force,divu,dx,dt, &
                the_bc_tower%bc_tower_array,is_vel,is_conservative)

    !***********************************
    ! Create scalar force at time n+1/2.
    !***********************************
    
    diff_fac = HALF
    call mkscalforce(nlevs,scal_force,ext_scal_force,laps,diff_fac)

    !***********************************
    ! Update the scalars with conservative or convective differencing.
    !***********************************

    call update(mla,sold,umac,sedge,sflux,scal_force,snew,aofs,dx,dt,is_vel, &
                is_conservative,the_bc_tower%bc_tower_array)

    if (verbose .ge. 1) then
       do n = 1, nlevs
          do comp = 1, nscal
             smin = multifab_min_c(snew(n),comp) 
             smax = multifab_max_c(snew(n),comp)
             if (comp .eq. 1) then
                if (parallel_IOProcessor()) write(6,2000) n,smin,smax
             else if (comp .eq. 2) then
                if (parallel_IOProcessor()) write(6,2001) n,smin,smax
             end if
          end do
       end do
    end if

    deallocate(is_conservative)

    do n = 1,nlevs
       call multifab_destroy(scal_force(n))
       call multifab_destroy(divu(n))
       do i = 1,dm
         call multifab_destroy(sflux(n,i))
         call multifab_destroy(sedge(n,i))
       end do
    enddo

    deallocate(umac_nodal_flag)
    deallocate(scal_force,divu,laps,sflux,sedge)

    if (diff_coef > ZERO) then
           comp = 2
           bc_comp = dm+comp
 
           ! Crank-Nicolson
           if (diffusion_type .eq. 1) then
              visc_mu = HALF*dt*diff_coef
 
           ! backward Euler
           else if (diffusion_type .eq. 2) then
              visc_mu = dt*diff_coef
 
           else
             call bl_error('BAD DIFFUSION TYPE ')
           end if
 
           call diff_scalar_solve(mla,snew,dx,visc_mu,the_bc_tower,comp,bc_comp)
    end if


2000 format('... level ', i2,' new min/max : density           ',e17.10,2x,e17.10)
2001 format('... level ', i2,' new min/max :  tracer           ',e17.10,2x,e17.10)

  end subroutine scalar_advance

  subroutine modify_force(a,targ,b,src_b,c,src_c,nc,mult,all)
    integer       , intent(in   )           :: targ, src_b, src_c
    integer       , intent(in   ), optional :: nc
    logical       , intent(in   ), optional :: all
    type(multifab), intent(inout)           :: a
    type(multifab), intent(in   )           :: b
    type(multifab), intent(in   )           :: c
    real(dp_t)    , intent(in   )           :: mult

    ! local
    real(dp_t), pointer :: ap(:,:,:,:)
    real(dp_t), pointer :: bp(:,:,:,:)
    real(dp_t), pointer :: cp(:,:,:,:)
    integer             :: i
    logical             :: lall

    lall = .false.; if ( present(all) ) lall = all
    !$OMP PARALLEL DO PRIVATE(i,ap,bp)
    do i = 1, a%nboxes
       if ( multifab_remote(a,i) ) cycle
       if ( lall ) then
          ap => dataptr(a, i, targ, nc)
          bp => dataptr(b, i, src_b, nc)
          cp => dataptr(c, i, src_c, nc)
       else
          ap => dataptr(a, i, get_ibox(a, i), targ, nc)
          bp => dataptr(b, i, get_ibox(b, i), src_b, nc)
          cp => dataptr(c, i, get_ibox(c, i), src_c, nc)
       end if
       ap = ap + mult*bp*cp
    end do
    !$OMP END PARALLEL DO
  end subroutine modify_force

end module scalar_advance_module