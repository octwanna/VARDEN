module multifab_physbc_module

  use multifab_module
  use define_bc_module

  implicit none

  private

  public :: multifab_physbc

contains

  subroutine multifab_physbc(s,start_scomp,start_bccomp,num_comp,the_bc_level,dx,t)

    use setbc_module

    type(multifab) , intent(inout) :: s
    integer        , intent(in   ) :: start_scomp,start_bccomp,num_comp
    type(bc_level) , intent(in   ) :: the_bc_level
    real(kind=dp_t), intent(in   ) :: dx(:)
    real(kind=dp_t), intent(in   ) :: t

    ! Local
    integer                  :: lo(s%dim)
    integer                  :: i,ng,dm,scomp,bccomp
    real(kind=dp_t), pointer :: sp(:,:,:,:)
    
    ng = s%ng
    dm = s%dim
    
    do i=1,s%nboxes
       if ( multifab_remote(s,i) ) cycle
       sp => dataptr(s,i)
       lo = lwb(get_box(s,i))
       select case (dm)
       case (2)
          do scomp = start_scomp,start_scomp+num_comp-1
             bccomp = start_bccomp + scomp - start_scomp
             call setbc_2d(sp(:,:,1,scomp), lo, ng, &
                           the_bc_level%adv_bc_level_array(i,:,:,bccomp),bccomp,dx,t)
          end do
       case (3)
          do scomp = start_scomp,start_scomp+num_comp-1
             bccomp = start_bccomp + scomp - start_scomp
             call setbc_3d(sp(:,:,:,scomp), lo, ng, &
                           the_bc_level%adv_bc_level_array(i,:,:,bccomp),bccomp,dx,t)
          end do
       end select
    end do
 
end subroutine multifab_physbc

end module multifab_physbc_module