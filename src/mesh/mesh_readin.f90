#include "hopest_f.h"

MODULE MOD_Mesh_ReadIn
!===================================================================================================================================
! Add comments please!
!===================================================================================================================================
! MODULES
USE MOD_HDF5_Input
! IMPLICIT VARIABLE HANDLING
IMPLICIT NONE
!-----------------------------------------------------------------------------------------------------------------------------------
! Private Part ---------------------------------------------------------------------------------------------------------------------

! Public Part ----------------------------------------------------------------------------------------------------------------------
INTERFACE ReadMeshFromHDF5
  MODULE PROCEDURE ReadMeshFromHDF5
END INTERFACE

PUBLIC::ReadMeshFromHDF5
!===================================================================================================================================

CONTAINS

SUBROUTINE ReadBCs()
!===================================================================================================================================
! Read boundary conditions from data file
!===================================================================================================================================
! MODULES
USE MOD_Globals
USE MOD_Mesh_Vars,ONLY:BoundaryName,BoundaryType,nBCs
! IMPLICIT VARIABLE HANDLING
IMPLICIT NONE
!-----------------------------------------------------------------------------------------------------------------------------------
! INPUT VARIABLES
!-----------------------------------------------------------------------------------------------------------------------------------
! OUTPUT VARIABLES
!-----------------------------------------------------------------------------------------------------------------------------------
! LOCAL VARIABLES
INTEGER                        :: iBC
INTEGER                        :: Offset=0 ! Every process reads all BCs
!===================================================================================================================================
offset=0
! Read boundary names from data file
CALL GetDataSize(File_ID,'BCNames',nDims,HSize)
nBCs=HSize(1)
DEALLOCATE(HSize)
IF(ALLOCATED(BoundaryName)) DEALLOCATE(BoundaryName)
IF(ALLOCATED(BoundaryType)) DEALLOCATE(BoundaryType)
ALLOCATE(BoundaryName(nBCs))
CALL ReadArray('BCNames',1,(/nBCs/),Offset,1,StrArray=BoundaryName)  

! Read boundary types from data file
CALL GetDataSize(File_ID,'BCType',nDims,HSize)
IF(HSize(1).NE.nBCs) STOP 'Problem in readBC'
DEALLOCATE(HSize)
ALLOCATE(BoundaryType(nBCs,4))
CALL ReadArray('BCType',2,(/nBCs,4/),Offset,1,IntegerArray=BoundaryType)

SWRITE(UNIT_StdOut,'(132("."))')
SWRITE(Unit_StdOut,'(A,A16,A20,A10,A10,A10,A10)')'BOUNDARY CONDITIONS','|','Name','Type','CurveInd','State','Alpha'
DO iBC=1,nBCs
  SWRITE(*,'(A,A33,A20,I10,I10,I10,I10)')' |','|',TRIM(BoundaryName(iBC)),BoundaryType(iBC,:)
END DO
SWRITE(UNIT_StdOut,'(132("."))')
END SUBROUTINE ReadBCs


SUBROUTINE ReadMeshFromHDF5(FileString)
!===================================================================================================================================
! Subroutine to read the mesh from a mesh data file
!===================================================================================================================================
! MODULES
USE MOD_Globals
USE MOD_Mesh_Vars
USE MOD_p4estBinding
! IMPLICIT VARIABLE HANDLING
IMPLICIT NONE
!-----------------------------------------------------------------------------------------------------------------------------------
! INPUT VARIABLES
CHARACTER(LEN=*),INTENT(IN)  :: FileString
!-----------------------------------------------------------------------------------------------------------------------------------
! OUTPUT VARIABLES
!-----------------------------------------------------------------------------------------------------------------------------------
! LOCAL VARIABLES
INTEGER                        :: i,j,k,l
INTEGER                        :: BCindex
INTEGER                        :: iElem,ElemID
INTEGER                        :: iNode,jNode,NodeID,SideID
INTEGER                        :: iLocSide,jLocSide
INTEGER                        :: iSide
INTEGER                        :: FirstNodeInd,LastNodeInd,FirstSideInd,LastSideInd
INTEGER                        :: nCurvedNodes_loc
LOGICAL                        :: oriented
INTEGER                        :: nPeriodicSides 
LOGICAL                        :: fileExists
LOGICAL                        :: doConnection
TYPE(tElem),POINTER            :: aElem
TYPE(tSide),POINTER            :: aSide,bSide
TYPE(tNode),POINTER            :: aNode
TYPE(tNodePtr),POINTER         :: ElemCurvedNode(:,:)
INTEGER,ALLOCATABLE            :: ElemInfo(:,:),SideInfo(:,:),NodeInfo(:)
REAL,ALLOCATABLE               :: NodeCoords(:,:)
                               
INTEGER                        :: BoundaryOrder_mesh
INTEGER                        :: nNodeIDs,nSideIDs
! p4est interface
INTEGER                        :: num_vertices
INTEGER                        :: num_trees
INTEGER,ALLOCATABLE            :: tree_to_vertex(:,:)
REAL,ALLOCATABLE               :: vertices(:,:)
!===================================================================================================================================
IF(MESHInitIsDone) RETURN
INQUIRE (FILE=TRIM(FileString), EXIST=fileExists)
IF(.NOT.FileExists)  &
    CALL abort(__STAMP__, &
       'readMesh from data file "'//TRIM(FileString)//'" does not exist')


SWRITE(UNIT_stdOut,'(A)')'READ MESH FROM DATA FILE "'//TRIM(FileString)//'" ...'
SWRITE(UNIT_StdOut,'(132("-"))')
! Open data file
CALL OpenDataFile(FileString,create=.FALSE.,single=.FALSE.)

CALL GetDataSize(File_ID,'ElemInfo',nDims,HSize)
nGlobalElems=HSize(1) !global number of elements
DEALLOCATE(HSize)
nElems=nGlobalElems   !local number of Elements 

CALL GetDataSize(File_ID,'NodeCoords',nDims,HSize)
nNodes=HSize(1) !global number of unique nodes
DEALLOCATE(HSize)

CALL readBCs()

CALL ReadAttribute(File_ID,'BoundaryOrder',1,IntegerScalar=BoundaryOrder_mesh)
NGeo = BoundaryOrder_mesh-1
CALL ReadAttribute(File_ID,'CurvedFound',1,LogicalScalar=useCurveds)

! mapping form one-dimensional list [1 ; (Ngeo+1)^3] to tensor-product 0 <= i,j,k <= Ngeo and back
ALLOCATE(HexMap(0:Ngeo,0:Ngeo,0:Ngeo),HexMapInv(3,(Ngeo+1)**3))
l=0
DO k=0,Ngeo ; DO j=0,Ngeo ; DO i=0,Ngeo
  l=l+1
  HexMap(i,j,k)=l
  HexMapInv(:,l)=(/i,j,k/)
END DO ; END DO ; END DO
!----------------------------------------------------------------------------------------------------------------------------
!                              ELEMENTS
!----------------------------------------------------------------------------------------------------------------------------

!read local ElemInfo from data file
ALLOCATE(ElemInfo(1:nElems,ELEM_InfoSize))
CALL ReadArray('ElemInfo',2,(/nElems,ELEM_InfoSize/),0,1,IntegerArray=ElemInfo)

ALLOCATE(Elems(1:nElems))

DO iElem=1,nElems
  iSide=ElemInfo(iElem,ELEM_FirstSideInd) !first index -1 in Sideinfo
  iNode=ElemInfo(iElem,ELEM_FirstNodeInd) !first index -1 in NodeInfo
  Elems(iElem)%ep=>GETNEWELEM()
  aElem=>Elems(iElem)%ep
  aElem%Ind    = iElem
  aElem%Type   = ElemInfo(iElem,ELEM_Type)
  aElem%Zone   = ElemInfo(iElem,ELEM_Zone)
END DO

!----------------------------------------------------------------------------------------------------------------------------
!                              NODES
!----------------------------------------------------------------------------------------------------------------------------

!read local Node Info from data file 
nNodeIDs=ElemInfo(nElems,ELEM_LastNodeInd)-ElemInfo(1,ELEM_FirstNodeInd)
ALLOCATE(NodeInfo(1:nNodeIDs))
CALL ReadArray('NodeInfo',1,(/nNodeIDs/),0,1,IntegerArray=NodeInfo)


IF(NGeo.GT.1)THEN
  nCurvedNodes=(NGeo+1)**3
ELSE
  nCurvedNodes=0
END IF

ALLOCATE(ElemCurvedNode(nCurvedNodes,nElems))

ALLOCATE(Nodes(1:nNodes)) ! pointer list, entry is known by NodeCoords
DO iNode=1,nNodes
  NULLIFY(Nodes(iNode)%np)
END DO
!assign nodes 
DO iElem=1,nElems
  aElem=>Elems(iElem)%ep
  iNode=ElemInfo(iElem,ELEM_FirstNodeInd) !first index -1 in NodeInfo
  DO jNode=1,8
    iNode=iNode+1
    NodeID=ABS(NodeInfo(iNode))     !global, unique NodeID
    IF(.NOT.ASSOCIATED(Nodes(NodeID)%np))THEN
      ALLOCATE(Nodes(NodeID)%np) 
      Nodes(NodeID)%np%ind=NodeID 
    END IF
    aElem%Node(jNode)%np=>Nodes(NodeID)%np
  END DO
  CALL createSides(aElem)
  IF(NGeo.GT.1)THEN
    nCurvedNodes_loc = ElemInfo(iElem,ELEM_LastNodeInd) - ElemInfo(iElem,ELEM_FirstNodeInd) - 14 ! corner + oriented nodes
    IF(nCurvedNodes.NE.nCurvedNodes_loc) &
      CALL abort(__STAMP__, &
           'Wrong number of curved nodes for hexahedra.')
    DO i=1,nCurvedNodes
      iNode=iNode+1
      NodeID=NodeInfo(iNode) !first oriented corner node
      IF(.NOT.ASSOCIATED(Nodes(NodeID)%np))THEN
        ALLOCATE(Nodes(NodeID)%np)
        Nodes(NodeID)%np%ind=NodeID 
      END IF
      ElemCurvedNode(i,iElem)%np=>Nodes(NodeID)%np
    END DO
  END IF
END DO

!----------------------------------------------------------------------------------------------------------------------------
!                              SIDES
!----------------------------------------------------------------------------------------------------------------------------

nSideIDs=ElemInfo(nElems,ELEM_LastSideInd)-ElemInfo(1,ELEM_FirstSideInd)
!read local SideInfo from data file 
ALLOCATE(SideInfo(1:nSideIDs,SIDE_InfoSize))
CALL ReadArray('SideInfo',2,(/nSideIDs,SIDE_InfoSize/),0,1,IntegerArray=SideInfo)

DO iElem=1,nElems
  aElem=>Elems(iElem)%ep
  iNode=ElemInfo(iElem,ELEM_LastNodeInd) !first index -1 in NodeInfo
  iNode=iNode-6
  iSide=ElemInfo(iElem,ELEM_FirstSideInd) !first index -1 in Sideinfo
  !build up sides of the element using element Nodes and CGNS standard
  ! assign flip
  DO iLocSide=1,6
    aSide=>aElem%Side(iLocSide)%sp
    iSide=iSide+1

    ElemID=SideInfo(iSide,SIDE_nbElemID) !IF nbElemID <0, this marks a mortar master side. 
                                         ! The number (-1,-2,-3) is the Type of mortar
    IF(ElemID.LT.0)THEN ! mortar Sides attached!
      CALL abort(__STAMP__, &
           'Only conforming meshes in readin.')
    END IF
   
    aSide%Elem=>aElem
    oriented=(Sideinfo(iSide,SIDE_ID).GT.0)
    
    aSide%Ind=ABS(SideInfo(iSide,SIDE_ID))
    iNode=iNode+1
    NodeID=NodeInfo(iNode) !first oriented corner node
    IF(oriented)THEN !oriented side
      aSide%flip=0
    ELSE !not oriented
      DO jNode=1,4
        IF(aSide%Node(jNode)%np%ind.EQ.ABS(NodeID)) EXIT
      END DO
      IF(jNode.GT.4) STOP 'NodeID doesnt belong to side'
      aSide%flip=jNode
    END IF

  END DO !i=1,locnSides
END DO !iElem

 
! build up side connection 
DO iElem=1,nElems
  aElem=>Elems(iElem)%ep
  iSide=ElemInfo(iElem,ELEM_FirstSideInd) !first index -1 in Sideinfo
  DO iLocSide=1,6
    aSide=>aElem%Side(iLocSide)%sp
    iSide=iSide+1

    sideID  = ABS(SideInfo(iSide,SIDE_ID))
    elemID  = SideInfo(iSide,SIDE_nbElemID)
    BCindex = SideInfo(iSide,SIDE_BCID)

    doConnection=.TRUE. ! for periodic sides if BC is reassigned as non periodic
    IF(BCindex.NE.0)THEN !BC
      aSide%BCindex = BCindex
      IF(BoundaryType(aSide%BCindex,BC_TYPE).NE.1)THEN ! Reassignement from periodic to non-periodic
        doConnection=.FALSE.
        aSide%flip  =0
        elemID            = 0
      END IF
    ELSE
      aSide%BCindex = 0
    END IF

    IF(.NOT.ASSOCIATED(aSide%connection))THEN
      IF((elemID.NE.0).AND.doConnection)THEN !connection 
        IF((elemID.LE.nElems).AND.(elemID.GE.1))THEN !local connection
          DO jLocSide=1,6
            bSide=>Elems(elemID)%ep%Side(jLocSide)%sp
            IF(bSide%ind.EQ.aSide%ind)THEN
              aSide%connection=>bSide
              bSide%connection=>aSide
              EXIT
            END IF !bSide%ind.EQ.aSide%ind
          END DO !jLocSide
        ELSE !MPI connection
          CALL abort(__STAMP__, &
            ' elemID of neighbor not in global Elem list ')
        END IF
      END IF
    END IF !connection associated
  END DO !iLocSide 
END DO !iElem

DEALLOCATE(ElemInfo,SideInfo,NodeInfo)

! get physical coordinates

ALLOCATE(NodeCoords(nNodes,3))

CALL ReadArray('NodeCoords',2,(/nNodes,3/),0,1,RealArray=NodeCoords)

ALLOCATE(Xgeo(1:3,0:Ngeo,0:Ngeo,0:Ngeo,nElems))
IF(Ngeo.EQ.1)THEN !use the corner nodes
  DO iElem=1,nElems
    aElem=>Elems(iElem)%ep
    Xgeo(:,0,0,0,iElem)=NodeCoords(aElem%Node(1)%np%ind,:)
    Xgeo(:,1,0,0,iElem)=NodeCoords(aElem%Node(2)%np%ind,:)
    Xgeo(:,1,1,0,iElem)=NodeCoords(aElem%Node(3)%np%ind,:)
    Xgeo(:,0,1,0,iElem)=NodeCoords(aElem%Node(4)%np%ind,:)
    Xgeo(:,0,0,1,iElem)=NodeCoords(aElem%Node(5)%np%ind,:)
    Xgeo(:,1,0,1,iElem)=NodeCoords(aElem%Node(6)%np%ind,:)
    Xgeo(:,1,1,1,iElem)=NodeCoords(aElem%Node(7)%np%ind,:)
    Xgeo(:,0,1,1,iElem)=NodeCoords(aElem%Node(8)%np%ind,:)
 END DO !iElem=1,nElems
ELSE
  DO iElem=1,nElems
    aElem=>Elems(iElem)%ep
    l=0
    DO k=0,Ngeo; DO j=0,Ngeo; DO i=0,Ngeo
      l=l+1
      Xgeo(:,i,j,k,iElem)=NodeCoords(ElemCurvedNode(l,iElem)%np%ind,:)
    END DO ; END DO ; END DO 
 END DO !iElem=1,nElems
END IF

CALL CloseDataFile() 

DEALLOCATE(ElemCurvedNode)
! P4est MESH connectivity (should be replaced by connectivity information ?)

! needs unique corner nodes for mesh connectivity
DO iNode=1,nNodes
  Nodes(iNode)%np%tmp=-1
END DO
num_vertices=0
DO iElem=1,nElems
  aElem=>Elems(iElem)%ep
  DO iNode=1,8
    aNode=>aElem%Node(iNode)%np
    IF(aNode%tmp.EQ.-1)THEN
      num_vertices=num_vertices+1
      aElem%Node(iNode)%np%tmp=num_vertices
    END IF
  END DO
END DO !iElem

ALLOCATE(Vertices(3,num_vertices))
DO iNode=1,nNodes
  aNode=>Nodes(iNode)%np
  IF(aNode%tmp.GT.0)THEN
    Vertices(:,aNode%tmp)=NodeCoords(aNode%ind,:)
  END IF
END DO


DEALLOCATE(NodeCoords)

num_trees=nElems
ALLOCATE(tree_to_vertex(8,num_trees))
DO iElem=1,nElems
  aElem=>Elems(iElem)%ep
  DO iNode=1,8
    tree_to_vertex(iNode,iElem)=aElem%Node(H2P_VertexMap(iNode)+1)%np%tmp-1
  END DO
END DO
CALL p4_connectivity_treevertex(num_vertices,num_trees,vertices,tree_to_vertex,p4est_ptr%p4est)

DEALLOCATE(Vertices,tree_to_vertex)
 

! COUNT SIDES

 
nBCSides=0
nSides=0
nPeriodicSides=0
DO iElem=1,nElems
  aElem=>Elems(iElem)%ep
  DO iLocSide=1,6
    aSide=>aElem%Side(iLocSide)%sp
    aSide%tmp=0 
  END DO !iLocSide
END DO !iElem
DO iElem=1,nElems
  aElem=>Elems(iElem)%ep
  DO iLocSide=1,6
    aSide=>aElem%Side(iLocSide)%sp

    IF(aSide%tmp.EQ.0)THEN
      nSides=nSides+1
      aSide%tmp=-1 !used as marker
      IF(ASSOCIATED(aSide%connection)) aSide%connection%tmp=-1
      IF(aSide%BCindex.NE.0)THEN !side is BC or periodic side
        IF(ASSOCIATED(aSide%connection))THEN
          nPeriodicSides=nPeriodicSides+1
        ELSE
          nBCSides=nBCSides+1
        END IF
      END IF
    END IF
  END DO !iLocSide
END DO !iElem


WRITE(*,*)'-------------------------------------------------------'
WRITE(*,'(A22,I8)' )'NGeo:',NGeo
WRITE(*,'(A22,X7L)')'useCurveds:',useCurveds
WRITE(*,'(A22,I8)' )'nElems:',nElems
WRITE(*,'(A22,I8)' )'nNodes:',nNodes
WRITE(*,'(A22,I8)' )'nSides:',nSides
WRITE(*,'(A22,I8)' )'nBCSides:',nBCSides
WRITE(*,'(A22,I8)' )'nPeriodicSides:',nPeriodicSides
WRITE(*,*)'-------------------------------------------------------'

END SUBROUTINE ReadMeshFromHDF5


!SUBROUTINE ReadMeshFromP4EST(FileString)
!!===================================================================================================================================
!! Subroutine to read the mesh from a mesh data file
!!===================================================================================================================================
!! MODULES
!USE MOD_Globals
!USE MOD_Mesh_Vars
!USE MOD_p4estBinding
!! IMPLICIT VARIABLE HANDLING
!IMPLICIT NONE
!!-----------------------------------------------------------------------------------------------------------------------------------
!! INPUT VARIABLES
!CHARACTER(LEN=*),INTENT(IN)  :: FileString
!!-----------------------------------------------------------------------------------------------------------------------------------
!! OUTPUT VARIABLES
!!-----------------------------------------------------------------------------------------------------------------------------------
!! LOCAL VARIABLES
!INTEGER                     :: i,j,k,l
!INTEGER                     :: iQuad,iMortar,iLocSide,iTree
!INTEGER                     :: nbQuadInd
!TYPE(C_PTR)                 :: QT,QQ,QF,QH
!TYPE(tElem),POINTER         :: aQuad,nbQuad,Tree
!TYPE(tSide),POINTER         :: aSide,nbSide
!INTEGER                     :: PMortar,PFlip,HFlip,QHInd
!INTEGER                     :: BClocSide,BCindex
!!-----------------------------------------------------------------------------------------------------------------------------------

!! Load p4est mesh from file
!CALL p4_loadmesh(FileString,p4est_ptr%p4est)
!CALL p4_get_mesh_info(p4est_ptr%p4est,p4est_ptr%mesh,nQuadrants,nHalfFaces)
!ALLOCATE(QuadCoords(3,nQuadrants),QuadLevel(nQuadrants)) ! big to small flip
!QuadCoords=0
!QuadLevel=0
!CALL p4_get_quadrants(p4est_ptr%p4est,p4est_ptr%mesh,nQuadrants,nHalfFaces,& !IN
                      !intsize,QT,QQ,QF,QH,QuadCoords,QuadLevel)              !OUT

!CALL C_F_POINTER(QT,QuadToTree,(/nQuadrants/))
!CALL C_F_POINTER(QQ,QuadToQuad,(/6,nQuadrants/))
!CALL C_F_POINTER(QF,QuadToFace,(/6,nQuadrants/))
!IF(nHalfFaces.GT.0) CALL C_F_POINTER(QH,QuadToHalf,(/4,nHalfFaces/))

!!----------------------------------------------------------------------------------------------------------------------------
!!             Start to build p4est datastructure in HOPEST
!!----------------------------------------------------------------------------------------------------------------------------
!!                              ELEMENTS
!!----------------------------------------------------------------------------------------------------------------------------

!!read local ElemInfo from data file
!ALLOCATE(Quads(1:nQuadrants))
!DO iQuad=1,nQuadrants
  !Quads(iQuad)%ep=>GETNEWELEM()
  !aQuad=>Quads(iQuad)%ep
  !aQuad%Ind    = iQuad
  !CALL CreateSides(aQuad)
  !DO iLocSide=1,6
    !aQuad%Side(iLocSide)%sp%flip=-999
  !END DO
!END DO


!DO iQuad=1,nQuadrants
  !aQuad=>Quads(iQuad)%ep
  !aQuad%type=0
  !DO iLocSide=1,6
    !aSide=>aQuad%Side(iLocSide)%sp
    !! Get P4est local side
    !PSide=H2P_FaceMap(iLocSide)
    !! Get P4est neighbour side/flip/morter
    !CALL EvalP4ESTConnectivity(QuadToFace(PSide+1,iQuad),PnbSide,PFlip,PMortar)
    !! transform p4est orientation to HOPR flip (magic)
    !HFlip=GetHFlip(PSide,PnbSide,PFlip)  !Hflip of neighbor side!!!
    !IF(PMortar.EQ.4)THEN
      !! Neighbour side is mortar (4 sides), all neighbour element sides have same orientation and local side ind
      !QHInd=QuadToQuad(PSide+1,iQuad)+1
      !aSide%nMortars=4
      !aSide%MortarType=1             ! 1->4 case
      !ALLOCATE(aSide%MortarSide(4))
      !DO iMortar=1,4
        !nbQuadInd=QuadToHalf(iMortar,QHInd)+1
        !nbQuad=>Quads(nbQuadInd)%ep
        !nbSide=P2H_FaceMap(PnbSide)
        !aSide%MortarSide(iMortar)%sp=>nbQuad%side(nbSide)%sp
        !aSide%MortarSide(iMortar)%sp%flip=HFlip
      !END DO ! iMortar
    !ELSE
      !nbQuadInd=QuadToQuad(PSide+1,iQuad)+1
      !nbQuad=>Quads(nbQuadInd)%ep
      !nbSide=P2H_FaceMap(PnbSide)
      !IF((nbQuadInd.EQ.iQuad).AND.(nbSide.EQ.iLocSide))THEN
        !! this is a boundary side: 
        !BCindex=TreeBCMap(iLocSide,iTree)
        !IF(BCIndex.EQ.0) STOP 'Problem in Boundary assignment'
        !aSide%BCIndex=BCIndex
        !NULLIFY(aSide%connection)
        !aSide%Flip=0
        
      !ELSE
        !aSide%connection=>nbQuad%side(nbSide)%sp
        !aSide%connection%flip=HFlip
      !END IF !BC side
      !IF(PMortar.NE.-1) aSide%MortarType= - (PMortar+1)  ! Pmortar 0...3, small side belonging to  mortar group -> -1..-4
    !END IF ! PMortar
  !END DO
!END DO

!END SUBROUTINE ReadMeshFromP4EST


END MODULE MOD_Mesh_ReadIn
