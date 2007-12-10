module viscous_module

  use bl_constants_module
  use bc_module
  use bl_types
  use multifab_module
  use boxarray_module
  use stencil_module
  use macproject_module
  use ml_layout_module
  use define_bc_module
  use bndry_reg_module
  use multifab_physbc_module
  use multifab_fill_ghost_module
  use ml_restriction_module

  implicit none

  private
  public :: visc_solve, diff_scalar_solve

contains 

  subroutine visc_solve(mla,unew,rho,dx,mu,the_bc_tower,mg_verbose,cg_verbose,verbose)

    type(ml_layout), intent(inout) :: mla
    type(multifab ), intent(inout) :: unew(:)
    type(multifab ), intent(in   ) :: rho(:)
    real(dp_t)     , intent(in   ) :: dx(:,:),mu
    type(bc_tower ), intent(in   ) :: the_bc_tower
    integer        , intent(in   ) :: mg_verbose,cg_verbose,verbose

    ! Local  
    type(multifab), allocatable :: rh(:),phi(:),alpha(:),beta(:)
    type(bndry_reg), pointer    :: fine_flx(:) => Null()
    real(kind=dp_t), pointer    :: unp(:,:,:,:)
    integer                     :: n,nlevs,d,dm,i,comp
    integer                     :: bc_comp,stencil_order,ng_cell
    integer                     :: lo(unew(1)%dim)
    real(kind=dp_t)             :: norm1(mla%nlevel), norm2(mla%nlevel)

    nlevs = mla%nlevel
    dm    = mla%dim
    ng_cell = unew(1)%ng

    allocate(rh(nlevs),phi(nlevs),alpha(nlevs),beta(nlevs))

    do n = 1,nlevs
       call multifab_build(   rh(n), mla%la(n),  1, 0)
       call multifab_build(  phi(n), mla%la(n),  1, 1)
       call multifab_build(alpha(n), mla%la(n),  1, 1)
       call multifab_build( beta(n), mla%la(n), dm, 1)

       call multifab_copy_c(alpha(n),1,rho(n),1,1)
       call setval(beta(n),mu,all=.true.)
    end do

    stencil_order = 2

    if (verbose .ge. 1) then
       do n = 1,nlevs
          norm1(n) = norm_inf(unew(n),1,1)
          norm2(n) = norm_inf(unew(n),2,1)
       end do
       if (parallel_IOProcessor()) then
          print *,' '
          print *,'... begin viscous solves  ... '
          do n = 1,nlevs
             print *,'BEFORE: MAX OF U AT LEVEL ',n,norm1(n)
             print *,'BEFORE: MAX OF V AT LEVEL ',n,norm2(n)
          end do
       end if
    endif

    allocate(fine_flx(2:nlevs))
    do n = 2,nlevs
       call bndry_reg_build(fine_flx(n),mla%la(n),ml_layout_get_pd(mla,n))
    end do

    do d = 1,dm
       do n = 1,nlevs
          call mkrhs(rh(n),unew(n),rho(n),phi(n),d)
       end do
       bc_comp = d
       call mac_multigrid(mla,rh,phi,fine_flx,alpha,beta,dx, &
                          the_bc_tower,bc_comp,stencil_order,mla%mba%rr, &
                          mg_verbose,cg_verbose)
       do n = 1,nlevs
          call multifab_copy_c(unew(n),d,phi(n),1,1)
       end do
    end do

    do n = 1, nlevs
       call multifab_fill_boundary(unew(n))
    enddo

    do n = 1, nlevs
       call multifab_physbc(unew(n),1,1,dm,dx(n,:),the_bc_tower%bc_tower_array(n))
    enddo

    do n = nlevs, 2, -1
       call ml_cc_restriction(unew(n-1),unew(n),mla%mba%rr(n-1,:))
    enddo

    do n = 2, nlevs
       call multifab_fill_ghost_cells(unew(n),unew(n-1), &
                                      ng_cell,mla%mba%rr(n-1,:), &
                                      the_bc_tower%bc_tower_array(n-1), &
                                      the_bc_tower%bc_tower_array(n  ), &
                                      1,1,dm)
    end do

    if (verbose .ge. 1) then
       do n = 1,nlevs
          norm1(n) = norm_inf(unew(n),1,1)
          norm2(n) = norm_inf(unew(n),2,1)
       end do
       if (parallel_IOProcessor()) then
          do n = 1,nlevs
             print *,' AFTER: MAX OF U AT LEVEL ',n,norm1(n)
             print *,' AFTER: MAX OF V AT LEVEL ',n,norm2(n)
          end do
          print *,'...   end viscous solves  ... '
          print *,' '
       end if
    endif

    do n = 1, nlevs
       call multifab_destroy(rh(n))
       call multifab_destroy(phi(n))
       call multifab_destroy(alpha(n))
       call multifab_destroy(beta(n))
    end do

    deallocate(rh)
    deallocate(phi)
    deallocate(alpha)
    deallocate(beta)
    do n = 2,nlevs
       call bndry_reg_destroy(fine_flx(n))
    end do
    deallocate(fine_flx)

  contains

    subroutine mkrhs(rh,unew,rho,phi,comp)

      type(multifab) , intent(in   ) :: unew,rho
      type(multifab) , intent(inout) :: rh,phi
      integer        , intent(in   ) :: comp

      real(kind=dp_t), pointer :: unp(:,:,:,:)
      real(kind=dp_t), pointer :: rhp(:,:,:,:)
      real(kind=dp_t), pointer ::  rp(:,:,:,:)
      real(kind=dp_t), pointer ::  pp(:,:,:,:)
      integer :: i,dm,ng_u,ng_rho

      dm     = rh%dim
      ng_u   = unew%ng
      ng_rho = rho%ng

      do i = 1, unew%nboxes
         if ( multifab_remote(unew, i) ) cycle
         rhp => dataptr(rh  , i)
         unp => dataptr(unew, i)
         rp => dataptr(rho , i)
         pp => dataptr(phi , i)
         select case (dm)
         case (2)
            call mkrhs_2d(rhp(:,:,1,1), unp(:,:,1,comp), rp(:,:,1,1), &
                          pp(:,:,1,1), ng_u, ng_rho)
         case (3)
            call mkrhs_3d(rhp(:,:,:,1), unp(:,:,:,comp), rp(:,:,:,1), &
                          pp(:,:,:,1), ng_u, ng_rho)
         end select
      end do

    end subroutine mkrhs

    subroutine mkrhs_2d(rh,unew,rho,phi,ng_u,ng_rho)

      integer        , intent(in   ) :: ng_u,ng_rho
      real(kind=dp_t), intent(inout) ::   rh(        :,        :)
      real(kind=dp_t), intent(in   ) :: unew(1-ng_u  :,1-ng_u  :)
      real(kind=dp_t), intent(in   ) ::  rho(1-ng_rho:,1-ng_rho:)
      real(kind=dp_t), intent(inout) ::  phi(       0:,       0:)

      integer :: nx,ny

      nx = size(rh,dim=1)
      ny = size(rh,dim=2)

      rh(1:nx  ,1:ny  ) = unew(1:nx  ,1:ny  ) * rho(1:nx,1:ny)
      phi(0:nx+1,0:ny+1) = unew(0:nx+1,0:ny+1)

    end subroutine mkrhs_2d

    subroutine mkrhs_3d(rh,unew,rho,phi,ng_u,ng_rho)

      integer        , intent(in   ) :: ng_u,ng_rho
      real(kind=dp_t), intent(inout) ::   rh(        :,        :,        :)
      real(kind=dp_t), intent(in   ) :: unew(1-ng_u  :,1-ng_u  :,1-ng_u  :)
      real(kind=dp_t), intent(in   ) ::  rho(1-ng_rho:,1-ng_rho:,1-ng_rho:)
      real(kind=dp_t), intent(inout) ::  phi(       0:,       0:,       0:)

      integer :: nx,ny,nz

      nx = size(rh,dim=1)
      ny = size(rh,dim=2)
      nz = size(rh,dim=3)

      phi(0:nx+1,0:ny+1,0:nz+1) = unew(0:nx+1,0:ny+1,0:nz+1)
      rh(1:nx  ,1:ny  ,1:nz  ) = unew(1:nx  ,1:ny  ,1:nz  ) * &
           rho(1:nx  ,1:ny  ,1:nz  )

    end subroutine mkrhs_3d

  end subroutine visc_solve

  subroutine diff_scalar_solve(mla,snew,dx,mu,the_bc_tower,icomp,bc_comp,mg_verbose, &
                               cg_verbose,verbose)

    type(ml_layout), intent(inout) :: mla
    type(multifab ), intent(inout) :: snew(:)
    real(dp_t)     , intent(in   ) :: dx(:,:)
    real(dp_t)     , intent(in   ) :: mu
    type(bc_tower ), intent(in   ) :: the_bc_tower
    integer        , intent(in   ) :: icomp,bc_comp
    integer        , intent(in   ) :: mg_verbose, cg_verbose, verbose

    ! Local  
    type(multifab), allocatable :: rh(:),phi(:),alpha(:),beta(:)
    type(bndry_reg), pointer    :: fine_flx(:) => Null()
    real(kind=dp_t), pointer    :: snp(:,:,:,:)
    integer                     :: i,n,nlevs,dm,stencil_order
    integer                     :: lo(snew(1)%dim),ng_cell
    real(kind=dp_t)             :: norm1(mla%nlevel)

    nlevs = mla%nlevel
    dm    = mla%dim
    ng_cell = snew(1)%ng

    allocate (rh(nlevs),phi(nlevs),alpha(nlevs),beta(nlevs))

    do n = 1,nlevs
       call multifab_build(   rh(n), mla%la(n),  1, 0)
       call multifab_build(  phi(n), mla%la(n),  1, 1)
       call multifab_build(alpha(n), mla%la(n),  1, 1)
       call multifab_build( beta(n), mla%la(n), dm, 1)
       call setval(alpha(n),ONE,all=.true.)
       call setval( beta(n), mu,all=.true.)
    end do

    if (verbose .ge. 1) then
       do n = 1,nlevs
          norm1(n) = norm_inf(snew(n),icomp,1)
       end do
       if (parallel_IOProcessor()) then
          print *,' '
          print *,'... begin diffusive solve  ... '
          do n = 1,nlevs
             print *,'BEFORE: MAX OF S AT LEVEL ',n,norm1(n)
          end do
       end if
    endif

    do n = 1,nlevs
       call mkrhs(rh(n),snew(n),phi(n),icomp)
    end do

    stencil_order = 2

    allocate(fine_flx(2:nlevs))
    do n = 2,nlevs
       call bndry_reg_build(fine_flx(n),mla%la(n),ml_layout_get_pd(mla,n))
    end do

    call mac_multigrid(mla,rh,phi,fine_flx,alpha,beta,dx, &
                       the_bc_tower,bc_comp,stencil_order,mla%mba%rr,mg_verbose,cg_verbose)

    do n = 1,nlevs
       call multifab_copy_c(snew(n),icomp,phi(n),1,1)
    end do

    do n = nlevs, 2, -1
       call ml_cc_restriction_c(snew(n-1),icomp,snew(n),icomp,mla%mba%rr(n-1,:),1)
    enddo

    if (verbose .ge. 1) then
       do n = 1,nlevs
          norm1(n) = norm_inf(snew(n),icomp,1)
       end do
       if (parallel_IOProcessor()) then
          do n = 1,nlevs
             print *,'AFTER: MAX OF S AT LEVEL ',n,norm1(n)
          end do
          print *,' '
          print *,'...   end diffusive solve  ... '
       end if
    endif

    do n = 1, nlevs
       call multifab_fill_boundary_c(snew(n),icomp,1)
    enddo

    do n = 1, nlevs
       call multifab_physbc(snew(n),icomp,bc_comp,1,dx(n,:),the_bc_tower%bc_tower_array(n))
    enddo

    do n = nlevs, 2, -1
       call ml_cc_restriction_c(snew(n-1),icomp,snew(n),icomp,mla%mba%rr(n-1,:),1)
    enddo

    do n = 2, nlevs
       call multifab_fill_ghost_cells(snew(n),snew(n-1), &
                                      ng_cell,mla%mba%rr(n-1,:), &
                                      the_bc_tower%bc_tower_array(n-1), &
                                      the_bc_tower%bc_tower_array(n  ), &
                                      icomp,bc_comp,1)
    end do

    do n = 1, nlevs
       call multifab_destroy(rh(n))
       call multifab_destroy(phi(n))
       call multifab_destroy(alpha(n))
       call multifab_destroy(beta(n))
    end do

    deallocate(rh)
    deallocate(phi)
    deallocate(alpha)
    deallocate(beta)
    do n = 2,nlevs
       call bndry_reg_destroy(fine_flx(n))
    end do
    deallocate(fine_flx)

  contains

    subroutine mkrhs(rh,snew,phi,comp)

      type(multifab) , intent(in   ) :: snew
      type(multifab) , intent(inout) :: rh,phi
      integer        , intent(in   ) :: comp

      real(kind=dp_t), pointer :: sp(:,:,:,:)
      real(kind=dp_t), pointer :: rp(:,:,:,:)
      real(kind=dp_t), pointer :: pp(:,:,:,:)
      integer :: i,dm,ng

      dm   = rh%dim
      ng   = snew%ng

      do i = 1, snew%nboxes
         if ( multifab_remote(snew, i) ) cycle
         rp => dataptr(rh  , i)
         pp => dataptr(phi , i)
         sp => dataptr(snew, i)
         select case (dm)
         case (2)
            call mkrhs_2d(rp(:,:,1,1), sp(:,:,1,comp), pp(:,:,1,1), ng)
         case (3)
            call mkrhs_3d(rp(:,:,:,1), sp(:,:,:,comp), pp(:,:,:,1), ng)
         end select
      end do

    end subroutine mkrhs

    subroutine mkrhs_2d(rh,snew,phi,ng)

      integer        , intent(in   ) :: ng
      real(kind=dp_t), intent(inout) ::   rh(    :,    :)
      real(kind=dp_t), intent(in   ) :: snew(1-ng:,1-ng:)
      real(kind=dp_t), intent(inout) ::  phi(0   :,   0:)

      integer :: nx,ny

      nx = size(rh,dim=1)
      ny = size(rh,dim=2)

      rh(1:nx,1:ny) = snew(1:nx,1:ny)
      phi(0:nx+1,0:ny+1) = snew(0:nx+1,0:ny+1)

    end subroutine mkrhs_2d

    subroutine mkrhs_3d(rh,snew,phi,ng)

      integer        , intent(in   ) :: ng
      real(kind=dp_t), intent(inout) ::   rh(    :,    :,    :)
      real(kind=dp_t), intent(in   ) :: snew(1-ng:,1-ng:,1-ng:)
      real(kind=dp_t), intent(inout) ::  phi(0   :,   0:,   0:)

      integer :: nx,ny,nz

      nx = size(rh,dim=1)
      ny = size(rh,dim=2)
      nz = size(rh,dim=3)

      rh(1:nx,1:ny,1:nz) = snew(1:nx,1:ny,1:nz)
      phi(0:nx+1,0:ny+1,0:nz+1) = snew(0:nx+1,0:ny+1,0:nz+1)

    end subroutine mkrhs_3d

  end subroutine diff_scalar_solve

end module viscous_module
