
from __future__ import division

from functools import wraps

import numpy as np
cimport numpy as np

cimport libc.string as cstring
cimport cython
from libc.stdlib cimport malloc, realloc, free
from libc.math cimport floor, ceil
cimport cpython.set

from util cimport (c_periodic_direction, c_periodic_distance,
                   c_periodic_distance_sqr,
                   c_vector_length, c_vector_sqr_length,
                   wrapping_modulo)


cdef extern from "lj_forces.h":
    void PyLJFluid_evaluate_LJ_forces(double *, size_t, unsigned int *, double *, double,
                                      double, double, double)

cdef ensure_N3_array(arr):
    if not isinstance(arr, np.ndarray):
        raise TypeError("bad argument of type %s; must be an ndarray"
                        % (type(arr).__name__,))
    if arr.dtype != np.double:
        raise ValueError("bad array type %s; must be double" % (arr.dtype,))
    if not (len(arr.shape) == 2 and arr.shape[1] == 3):
        raise ValueError("bad array shape %s; must be (N,3)" % (arr.shape,))
    if not arr.flags.c_contiguous:
        raise ValueError("array must be C contiguous")
    return arr


cdef class NeighborsTable:

    def __cinit__(self, double r_forcefield_cutoff, double r_skin):
        self.r_forcefield_cutoff = r_forcefield_cutoff
        self.r_skin = r_skin
        self.neighbor_indices = NULL
        self.N_neighbors = 0
        self.N_allocated = 0

    def __dealloc__(self):
        free(self.neighbor_indices)

    def __reduce__(self):
        return (NeighborsTable, (self.r_forcefield_cutoff, self.r_skin))

    property size:
        def __get__(self):
            return self.N_neighbors

    property allocated_size:
        def __get__(self):
            return self.N_allocated

    cdef int add_neighbor(self, unsigned int i, unsigned int j) except -1:
        if self.N_neighbors == self.N_allocated:
            self.grow_table()
        self.neighbor_indices[2 * self.N_neighbors] = i
        self.neighbor_indices[2 * self.N_neighbors + 1] = j
        self.N_neighbors += 1

    cdef int grow_table(self) except -1:
        cdef size_t alloc_size = 8192
        if self.neighbor_indices == NULL:
            self.N_allocated = alloc_size
            self.neighbor_indices = <unsigned int*>malloc(self.N_allocated * 2 * sizeof(unsigned int))
        else:
            self.N_allocated += alloc_size
            self.neighbor_indices = <unsigned int*>realloc(self.neighbor_indices, self.N_allocated * 2 * sizeof(unsigned int))
        if self.neighbor_indices == NULL:
            raise MemoryError
        assert self.N_allocated > self.N_neighbors

    @cython.boundscheck(False)
    @cython.wraparound(False)
    @cython.nonecheck(False)
    cdef int _rebuild_neigbors(self, np.ndarray[double, ndim=2, mode='c'] positions, double box_size) except -1:
        ensure_N3_array(positions)
        cdef int i, j, k, N
        cdef double r_sqr, r_neighbor_sqr
        cdef double l, half_size
        N = positions.shape[0]

        self.N_neighbors = 0
        r_neighbor_sqr = (self.r_skin + self.r_forcefield_cutoff) ** 2
        half_size = 0.5 * box_size

        for i in range(N):
            for j in range(i+1, N):

                r_sqr = 0.0
                for k in range(3):
                    l = positions[i, k] - positions[j, k]
                    if l > half_size:
                        l -= box_size
                    elif l < -half_size:
                        l += box_size
                    r_sqr += l*l

                if r_sqr < r_neighbor_sqr:
                    self.add_neighbor(i, j)

    def rebuild_neighbors(self, op, box_size=None):
        if isinstance(op, BaseConfig):
            assert box_size is None
            positions = op.positions
            box_size = op.box_size
        else:
            positions = op
            assert box_size is not None
        self._rebuild_neigbors(positions, box_size)

    @cython.boundscheck(False)
    @cython.wraparound(False)
    @cython.nonecheck(False)
    def find_set_of_neighbors_within_distance(self, double r_cutoff,
                                              np.ndarray[double, ndim=2, mode='c'] positions,
                                              double box_size):
        cdef double *positions_p = <double *>np.PyArray_DATA(positions)
        cdef unsigned int* neighbor_indices = self.neighbor_indices
        cdef size_t N_neighbors = self.N_neighbors
        cdef unsigned int neighbor_i, inx_i, inx_j, k
        cdef double r2, r2_cutoff = r_cutoff**2
        collect = set()

        for neighbor_i in range(N_neighbors):
            inx_i = neighbor_indices[2 * neighbor_i]
            inx_j = neighbor_indices[2 * neighbor_i + 1]
            r2 = c_periodic_distance_sqr(positions_p + inx_i,
                                         positions_p + inx_j,
                                         box_size)
            if r2 <= r2_cutoff:
                assert inx_i < inx_j
                cpython.set.PySet_Add(collect, (inx_i, inx_j))

        return collect


def vectorize_method(func):
    @wraps(func, assigned=['__name__', '__doc__'])
    def inner(self, x):
        if isinstance(x, np.ndarray):
            return np.array([func(self, xi) for xi in x.flat]).reshape(x.shape)
        else:
            return func(self, x)
    return inner


cdef class ForceField:

    @cython.boundscheck(False)
    @cython.wraparound(False)
    @cython.nonecheck(False)
    cdef int _evaluate_forces(self,
                              np.ndarray[double, ndim=2, mode='c'] forces,
                              np.ndarray[double, ndim=2, mode='c'] positions,
                              double box_size,
                              NeighborsTable neighbors) except -1:
        cdef unsigned int* neighbor_indices = neighbors.neighbor_indices
        cdef size_t N_neighbors = neighbors.N_neighbors
        cdef unsigned int neighbor_i, inx_i, inx_j, k
        cdef double force[3], pos_i[3], pos_j[3], r_ij[3]

        forces.fill(0.0)
        for neighbor_i in range(N_neighbors):
            inx_i = neighbor_indices[2 * neighbor_i]
            inx_j = neighbor_indices[2 * neighbor_i + 1]

            for k in range(3): pos_i[k] = positions[inx_i, k]
            for k in range(3): pos_j[k] = positions[inx_j, k]
            c_periodic_direction(r_ij, pos_i, pos_j, box_size)

            self._evaluate_a_force(force, r_ij)
            for k in range(3): forces[inx_i, k] += force[k]
            for k in range(3): forces[inx_j, k] -= force[k]


    @cython.boundscheck(False)
    @cython.wraparound(False)
    @cython.nonecheck(False)
    cdef int _evaluate_excess_virial(self,
                                     double *res_p,
                                     np.ndarray[double, ndim=2, mode='c'] positions,
                                     double box_size,
                                     NeighborsTable neighbors) except -1:
        cdef unsigned int* neighbor_indices = neighbors.neighbor_indices
        cdef size_t N_neighbors = neighbors.N_neighbors
        cdef unsigned int neighbor_i, inx_i, inx_j, k
        cdef double force[3], pos_i[3], pos_j[3], r_ij[3], r, f, acc

        acc = 0.0
        for neighbor_i in range(N_neighbors):
            inx_i = neighbor_indices[2 * neighbor_i]
            inx_j = neighbor_indices[2 * neighbor_i + 1]

            for k in range(3): pos_i[k] = positions[inx_i, k]
            for k in range(3): pos_j[k] = positions[inx_j, k]
            c_periodic_direction(r_ij, pos_i, pos_j, box_size)

            r = c_vector_length(r_ij)
            self._evaluate_a_scalar_force(&f, r)

            acc += r * f

        res_p[0] = -acc

    cdef int _evaluate_potential(self, double *U_p,
                                 np.ndarray[double, ndim=2, mode='c'] positions,
                                 double box_size,
                                 NeighborsTable neighbors) except -1:

        cdef unsigned int* neighbor_indices = neighbors.neighbor_indices
        cdef size_t N_neighbors = neighbors.N_neighbors
        cdef unsigned int neighbor_i, inx_i, inx_j, k
        cdef double pos_i[3], pos_j[3], r, U, acc_U

        acc_U = 0.0
        for neighbor_i in range(N_neighbors):
            inx_i = neighbor_indices[2 * neighbor_i]
            inx_j = neighbor_indices[2 * neighbor_i + 1]

            for k in range(3): pos_i[k] = positions[inx_i, k]
            for k in range(3): pos_j[k] = positions[inx_j, k]
            r = c_periodic_distance(pos_i, pos_j, box_size)
            self._evaluate_a_potential(&U, r)
            acc_U += U

        U_p[0] = acc_U


    @cython.cdivision(True)
    @cython.boundscheck(False)
    @cython.wraparound(False)
    cdef int _evaluate_a_force(self,
                               double force[3],
                               double r_ij[3]) except -1:
        cdef double f, r, scale
        cdef int k
        r = c_vector_length(r_ij)
        self._evaluate_a_scalar_force(&f, r)
        scale = f / r
        for k in range(3): force[k] = r_ij[k] * scale

    cdef int _evaluate_a_scalar_force(self, double *f_ptr, double r) except -1:
        raise RuntimeError("_evaluate_a_scalar_force not overrided in base class")

    cdef int _evaluate_a_potential(self, double *U_ptr, double r) except -1:
        raise RuntimeError("_evaluate_a_potential not overrided in base class")

    def evaluate_forces(self, forces, positions, double box_size, NeighborsTable neighbors):
        ensure_N3_array(forces)
        ensure_N3_array(positions)
        self._evaluate_forces(forces, positions, box_size, neighbors)
        return forces

    def evaluate_potential(self, positions, double box_size, NeighborsTable neighbors):
        ensure_N3_array(positions)
        cdef double U
        self._evaluate_potential(&U, positions, box_size, neighbors)
        return U / positions.shape[0]

    @vectorize_method
    def evaluate_scalar_force_function(self, double r):
        cdef double f
        self._evaluate_a_scalar_force(&f, r)
        return f

    @vectorize_method
    def evaluate_potential_function(self, double r):
        cdef double U
        self._evaluate_a_potential(&U, r)
        return U

    def evaluate_excess_virial(self, positions, double box_size, NeighborsTable neighbors):
        ensure_N3_array(positions)
        cdef double r
        self._evaluate_excess_virial(&r, positions, box_size, neighbors)
        return r / positions.shape[0]



@cython.cdivision(True)
cdef inline double evaluate_U612(double sigma, double epsilon, double r) nogil:
    cdef double x = sigma / r
    cdef double x2 = x*x
    cdef double x6 = x2*x2*x2
    return 4 * epsilon * (x6*x6 - x6)

@cython.cdivision(True)
cdef inline double evaluate_LJ_force(double sigma, double epsilon, double r) nogil:
    cdef double inv_r = 1.0 / r
    cdef double x = sigma * inv_r
    cdef double x2 = x*x
    cdef double x6 = x2*x2*x2
    return -4 * 6 * epsilon * inv_r * (2*x6*x6 - x6)


cdef class LJForceField(ForceField):

    def __cinit__(self, sigma=1.0, epsilon=1.0, r_cutoff=2.5):
        self.sigma = sigma
        self.epsilon = epsilon
        self.r_cutoff = r_cutoff
        self.U_shift = evaluate_U612(self.sigma, self.epsilon, self.r_cutoff)

    def __reduce__(self):
        return (LJForceField, (self.sigma, self.epsilon, self.r_cutoff))

    cdef int _evaluate_forces(self,
                              np.ndarray[double, ndim=2, mode='c'] forces,
                              np.ndarray[double, ndim=2, mode='c'] positions,
                              double box_size,
                              NeighborsTable neighbors) except -1:
        forces.fill(0.0)
        PyLJFluid_evaluate_LJ_forces(<double *>np.PyArray_DATA(forces),
                                     neighbors.N_neighbors,
                                     neighbors.neighbor_indices,
                                     <double *>np.PyArray_DATA(positions),
                                     box_size,
                                     self.sigma, self.epsilon, self.r_cutoff)

    @cython.cdivision(True)
    cdef int _evaluate_a_scalar_force(self, double *f_ptr, double r) except -1:
        if r >= self.r_cutoff:
            f_ptr[0] = 0.0
            return 0
        f_ptr[0] = evaluate_LJ_force(self.sigma, self.epsilon, r)

    @cython.cdivision(True)
    cdef int _evaluate_a_potential(self, double *U_ptr, double r) except -1:
        if r >= self.r_cutoff:
            U_ptr[0] = 0.0
            return 0
        U_ptr[0] = evaluate_U612(self.sigma, self.epsilon, r) - self.U_shift


cdef class BasePyForceField(ForceField):
    '''Allows Python derived classes to implement force field
       functionality
    '''

    pass

#     cdef _evaluate_forces(self, forces, positions, neighbors):
#         try:
#             ev = self.evaluate_force
#         except AttributeError:
#             super(BasePyForceField, self)._evaluate_forces(forces, positions, neighbors)
#         else:
#             ev(forces, positions, neighbors)

#     cdef _evaluate_potential(self, positions, neighbors):
#         try:
#             ev = self.evaluate_potential
#         except AttributeError:
#             super(BasePyForceField, self)._evaluate_potential(positions, neighbors)
#         else:
#             ev(positions, neighbors)




cdef class BaseConfig:

    def __cinit__(self,
                  np.ndarray[double, ndim=2, mode='c'] positions not None,
                  np.ndarray[double, ndim=2, mode='c'] last_positions,
                  double box_size,
                  double dt):
        ensure_N3_array(positions)
        if last_positions is None:
            last_positions = positions.copy()

        self.positions = positions
        self.last_positions = last_positions
        self.box_size = box_size
        self.dt = dt


cdef class BasePairCorrelationFunctionCalculator:

    cdef public:
        double r_prec, r_min, r_max
        size_t N_bins
        np.ndarray bins

    def __cinit__(self, r_prec, r_max, r_min=0.0, bins=None):
        cdef int N_bins = <int>ceil((r_max - r_min) / r_prec)
        if N_bins <= 0:
            raise ValueError("bad parameters")

        self.r_prec = r_prec
        self.r_min = r_min
        self.r_max = r_max
        self.N_bins = <size_t>N_bins
        if bins is None:
            bins = np.zeros(self.N_bins, dtype=np.uint)
        if bins.shape != (self.N_bins,) or bins.dtype != np.uint:
            raise TypeError("bad bins argument")
        self.bins = bins

    def __reduce__(self):
        return self.__class__, (self.r_prec, self.r_max, self.r_min, self.bins.copy())

    @cython.boundscheck(False)
    @cython.wraparound(False)
    @cython.cdivision(True)
    def accumulate_positions(self, np.ndarray[double, ndim=2, mode='c'] positions not None,
                             double box_size):
        cdef double *positions_p = <double *>np.PyArray_DATA(positions)
        cdef np.ndarray[unsigned long, ndim=1, mode='c'] bins = self.bins
        cdef size_t N3 = 3*positions.shape[0]
        cdef unsigned int i,j
        cdef int index
        cdef double r

        for i in range(0, N3, 3):
            for j in range(i+3, N3, 3):
                r = c_periodic_distance(positions_p + i, positions_p + j, box_size)
                index = <int>floor((r - self.r_min) / self.r_prec)
                if index >= 0 and index < self.N_bins:
                    bins[index] += 1

cdef void copy_N3_array_data(np.ndarray dst, np.ndarray src, unsigned int N) nogil:
    cstring.memcpy(<void *>np.PyArray_DATA(dst),
                   <void *>np.PyArray_DATA(src),
                   N * 3 * sizeof(double))


cdef class BaseMeanSquareDisplacementCalculator:

    cdef readonly:
        unsigned int window_size, N_particles, n_positions_seen
        double box_size
        np.ndarray displacement_window, last_positions, sum_displacements, acc_msd_data

    def __cinit__(self, unsigned int window_size, unsigned int N_particles, *args, **kwds):
        assert window_size > 0
        assert N_particles > 0

        self.window_size = window_size
        self.N_particles = N_particles
        self.n_positions_seen = 0

        self.displacement_window = np.empty((self.window_size, self.N_particles, 3), dtype=float)
        self.last_positions = np.empty((self.N_particles, 3), dtype=float)
        self.sum_displacements = np.empty((self.N_particles, 3), dtype=float)
        self.acc_msd_data = np.zeros(self.window_size, dtype=float)

    def __init__(self, window_size, N_particles):
        assert np.allclose(window_size, self.window_size)
        assert np.allclose(N_particles, self.N_particles)

    def analyze_positions(self, np.ndarray[double, ndim=2] positions not None, double box_size):
        assert positions.shape[0] == self.N_particles
        assert positions.shape[1] == 3

        if self.n_positions_seen:
            self.insert_displacments(positions, box_size)

        copy_N3_array_data(self.last_positions, positions, self.N_particles)
        self.n_positions_seen += 1

        if self.n_positions_seen > self.window_size:
            self.accumulate_mean_square_displacments()

    def calculate_n_accumulates(self):
        return max(self.n_positions_seen - self.window_size, 0)

    cdef inline double *get_displacement_window(self, unsigned int window_index) nogil:
        # normalize index
        window_index = wrapping_modulo(self.n_positions_seen - 1 + window_index, self.window_size)
        return ((<double *>np.PyArray_DATA(self.displacement_window)) +
                (window_index * self.N_particles * 3))

    @cython.boundscheck(False)
    @cython.wraparound(False)
    cdef void insert_displacments(self, np.ndarray positions, double box_size) nogil:
        '''Calculate displacement vectors from self.last_positions to positions.
           Store results in index 0 of the displacement window.
           Should be called before n_positions_seen is incremented so that
           we overwrite the oldest displacement window.
        '''
        cdef double *positions_p = <double *>np.PyArray_DATA(positions)
        cdef double *last_positions_p = <double *>np.PyArray_DATA(self.last_positions)
        cdef double *displacment_p = self.get_displacement_window(0)

        cdef unsigned int i
        for i in range(0, 3*self.N_particles, 3):
            c_periodic_direction(displacment_p + i, positions_p + i, last_positions_p + i, box_size)

    cdef void accumulate_mean_square_displacments(self) nogil:
        '''Move through displacement windows while accumulating
           the deltas to determine the displacement of each particle
           at each window in time.
        '''
        cdef double *sum_displacements_p = <double *>np.PyArray_DATA(self.sum_displacements)
        cdef double *acc_msd_data_p = <double *>np.PyArray_DATA(self.acc_msd_data)
        cdef double *displacement_slice
        cdef double delta, acc_sqr_delta
        cdef unsigned int N3 = 3*self.N_particles
        cdef unsigned int window_i, j

        cstring.memset(<void *>sum_displacements_p, 0, sizeof(double)*N3)

        for window_i in range(self.window_size):

            # Efficiently perform:
            #    self.sum_displacements += self.displacement_window[window_i]
            # while also accumulating square displacements

            acc_sqr_delta = 0
            displacement_slice = self.get_displacement_window(window_i)

            for j in range(N3):
                sum_displacements_p[j] += displacement_slice[j]
                delta = sum_displacements_p[j]
                acc_sqr_delta += delta*delta

            acc_msd_data_p[window_i] += acc_sqr_delta


cdef class BaseVelocityAutocorrelationCalculator:

    cdef readonly:
        unsigned int window_size, N_particles, n_velocities_seen
        np.ndarray velocities_windows, acc_correlations

    def __cinit__(self, unsigned int window_size, unsigned int N_particles, *args, **kwds):
        assert window_size > 0
        assert N_particles > 0

        self.window_size = window_size
        self.N_particles = N_particles
        self.n_velocities_seen = 0

        self.velocities_windows = np.empty((self.window_size, self.N_particles, 3), dtype=float)
        self.acc_correlations = np.zeros(self.window_size, dtype=float)

    def __init__(self, window_size, N_particles):
        assert np.allclose(window_size, self.window_size)
        assert np.allclose(N_particles, self.N_particles)

    cdef inline double *get_velocities_window(self, unsigned int window_index) nogil:
        # normalize index
        window_index = wrapping_modulo(self.n_velocities_seen + window_index, self.window_size)
        return ((<double *>np.PyArray_DATA(self.velocities_windows)) +
                (window_index * self.N_particles * 3))

    def analyze_velocities(self, np.ndarray[double, ndim=2] velocities not None):
        assert velocities.shape[0] == self.N_particles
        assert velocities.shape[1] == 3

        # overwrite oldest velocities window with newest data
        cstring.memcpy(<void *>self.get_velocities_window(0),
                       <void *>np.PyArray_DATA(velocities),
                       self.N_particles * 3 * sizeof(double))

        self.n_velocities_seen += 1
        if self.n_velocities_seen >= self.window_size:
            self.accumulate_velocity_correlations()

    def calculate_n_accumulates(self):
        return max(self.n_velocities_seen - self.window_size + 1, 0)

    cdef void accumulate_velocity_correlations(self) nogil:
        cdef double *acc_correlations_p = <double *>np.PyArray_DATA(self.acc_correlations)
        cdef double *velocities_0, *velocities_i
        cdef double acc
        cdef unsigned int window_i, j
        cdef unsigned int N3 = 3*self.N_particles

        velocities_0 = self.get_velocities_window(0)

        for window_i in range(self.window_size):

            velocities_i = self.get_velocities_window(window_i)
            acc = 0
            for j in range(N3):
                acc += velocities_0[j] * velocities_i[j]
            acc_correlations_p[window_i] = acc






