#!/bin/sh
### BEGIN INIT INFO
# Provides:             volatile
# Required-Start:       $local_fs
# Required-Stop:      $local_fs
# Default-Start:        S
# Default-Stop:
# Short-Description:  Populate the volatile filesystem
### END INIT INFO

# Get ROOT_DIR
DIRNAME=`dirname $0`
ROOT_DIR=`echo $DIRNAME | sed -ne 's:etc/.*::p'`

. ${ROOT_DIR}/etc/default/rcS
# When running populat-volatile.sh at rootfs time, disable cache.
[ "$ROOT_DIR" != "/" ] && VOLATILE_ENABLE_CACHE=no
# If rootfs is read-only, disable cache.
[ "$ROOTFS_READ_ONLY" = "yes" ] && VOLATILE_ENABLE_CACHE=no
# All above statements will be moved to a central place, say var.sh which
# encapsulates '. /etc/default/rcS'.

CFGDIR="${ROOT_DIR}/etc/default/volatiles"
TMPROOT="${ROOT_DIR}/var/volatile/tmp"
COREDEF="00_core"
READONLY_MATCH="readonly-"

[ "${VERBOSE}" != "no" ] && echo "Setting up basic files related to volatile storage under ${ROOT_DIR}."

create_file() {
	EXEC="
	touch \"$1\";
	chown ${TUSER}.${TGROUP} $1 || echo \"Failed to set owner -${TUSER}- for -$1-.\" > /dev/null 2>&1;
	chmod ${TMODE} $1 || echo \"Failed to set mode -${TMODE}- for -$1-.\" > /dev/null 2>&1 "

	test "$VOLATILE_ENABLE_CACHE" = yes && echo "$EXEC" >> /etc/volatile.cache.build

	[ -e "$1" ] && {
		[ "${VERBOSE}" != "no" ] && echo "Target $1 already exists. Skipping."
	} || {
		if [ "$ROOT_DIR" = "/" ]; then
			eval $EXEC
		else
			# Some operations at rootfs time may fail and should fail,
		        # but these failures should not be logged.
			eval $EXEC > /dev/null 2>&1
		fi
	}
}

mk_dir() {
	EXEC="
	mkdir -p \"$1\";
	chown ${TUSER}.${TGROUP} $1 || echo \"Failed to set owner -${TUSER}- for -$1-.\" 2>&1; 
	chmod ${TMODE} $1 || echo \"Failed to set mode -${TMODE}- for -$1-.\" 2>&1 "

	test "$VOLATILE_ENABLE_CACHE" = yes && echo "$EXEC" >> /etc/volatile.cache.build
	[ -e "$1" ] && {
		[ "${VERBOSE}" != "no" ] && echo "Target ${1} already exists. Skipping."
	} || {
		if [ "$ROOT_DIR" = "/" ]; then
			eval $EXEC
		else
			# Some operations at rootfs time may fail and should fail,
                        # but these failures should not be logged.
			eval $EXEC > /dev/null 2>&1
		fi
	}
}

link_file() {
	EXEC="
	if [ -L \"$2\" ]; then
		[ \"$(readlink -f \"$2\")\" != \"$(readlink -f \"$1\")\" ] && { rm -f \"$2\"; ln -sf \"$1\" \"$2\"; };
	elif [ -d \"$2\" ]; then
		for f in $2/* $2/.[^.]*; do [ -e $f ] && cp -rf $f $1; done;
		rm -rf \"$2\";
		ln -sf \"$1\" \"$2\";
	else
		ln -sf \"$1\" \"$2\";
	fi
        "
        test "$VOLATILE_ENABLE_CACHE" = yes && echo "   $EXEC" >> /etc/volatile.cache.build
	if [ "$ROOT_DIR" = "/" ]; then
		eval $EXEC
	else
		# Some operations at rootfs time may fail and should fail,
                # but these failures should not be logged
		eval $EXEC > /dev/null 2>&1
	fi
}

check_requirements() {
	cleanup() {
		rm "${TMP_INTERMED}"
		rm "${TMP_DEFINED}"
		rm "${TMP_COMBINED}"
	}
	
	CFGFILE="$1"
	[ `basename "${CFGFILE}"` = "${COREDEF}" ] && return 0
	# read-only-rootfs specific conf files should only be applied when rootfs is read-only
	case `basename "${CFGFILE}"` in
		${READONLY_MATCH}*)
		[ "$ROOTFS_READ_ONLY" = "yes" ] && return 0 || return 1
		;;
		*)
		;;
	esac

	TMP_INTERMED="${TMPROOT}/tmp.$$"
	TMP_DEFINED="${TMPROOT}/tmpdefined.$$"
	TMP_COMBINED="${TMPROOT}/tmpcombined.$$"

	cat ${ROOT_DIR}/etc/passwd | sed 's@\(^:\)*:.*@\1@' | sort | uniq > "${TMP_DEFINED}"
	cat ${CFGFILE} | grep -v "^#" | cut -d " " -f 2 > "${TMP_INTERMED}"
	cat "${TMP_DEFINED}" "${TMP_INTERMED}" | sort | uniq > "${TMP_COMBINED}"
	NR_DEFINED_USERS="`cat "${TMP_DEFINED}" | wc -l`"
	NR_COMBINED_USERS="`cat "${TMP_COMBINED}" | wc -l`"

	[ "${NR_DEFINED_USERS}" -ne "${NR_COMBINED_USERS}" ] && {
		echo "Undefined users:"
		diff "${TMP_DEFINED}" "${TMP_COMBINED}" | grep "^>"
		cleanup
		return 1
	}


	cat ${ROOT_DIR}/etc/group | sed 's@\(^:\)*:.*@\1@' | sort | uniq > "${TMP_DEFINED}"
	cat ${CFGFILE} | grep -v "^#" | cut -d " " -f 3 > "${TMP_INTERMED}"
	cat "${TMP_DEFINED}" "${TMP_INTERMED}" | sort | uniq > "${TMP_COMBINED}"

	NR_DEFINED_GROUPS="`cat "${TMP_DEFINED}" | wc -l`"
	NR_COMBINED_GROUPS="`cat "${TMP_COMBINED}" | wc -l`"

	[ "${NR_DEFINED_GROUPS}" -ne "${NR_COMBINED_GROUPS}" ] && {
		echo "Undefined groups:"
		diff "${TMP_DEFINED}" "${TMP_COMBINED}" | grep "^>"
		cleanup
		return 1
	}

	cleanup
	return 0
}

apply_cfgfile() {
	CFGFILE="$1"
	[ ${VERBOSE} != "no" ] && echo "Applying config file: $CFGFILE"

	check_requirements "${CFGFILE}" || {
		echo "Skipping ${CFGFILE}"
		return 1
	}

	cat ${CFGFILE} | grep -v "^#" | sed -e '/^$/ d' | \
		while read LINE; do
		eval `echo "$LINE" | sed -n "s/\(.*\)\ \(.*\) \(.*\)\ \(.*\)\ \(.*\)\ \(.*\)/TTYPE=\1 ; TUSER=\2; TGROUP=\3; TMODE=\4; TNAME=\5 TLTARGET=\6/p"`
		TNAME=${ROOT_DIR}/${TNAME}
		[ "${VERBOSE}" != "no" ] && echo "Checking for -${TNAME}-."

		[ "${TTYPE}" = "l" ] && {
			TSOURCE="$TLTARGET"
			[ "${VERBOSE}" != "no" ] && echo "Creating link -${TNAME}- pointing to -${TSOURCE}-."
			link_file "${TSOURCE}" "${TNAME}"
			continue
		}
		case "${TTYPE}" in
			"f")  [ "${VERBOSE}" != "no" ] && echo "Creating file -${TNAME}-."
				create_file "${TNAME}"
				;;
			"d")  [ "${VERBOSE}" != "no" ] && echo "Creating directory -${TNAME}-."
				mk_dir "${TNAME}"
				;;
			*)    [ "${VERBOSE}" != "no" ] && echo "Invalid type -${TTYPE}-."
				continue
				;;
		esac
	done
	return 0
}

if test -e ${ROOT_DIR}/etc/volatile.cache -a $VOLATILE_ENABLE_CACHE = yes -a x$1 != xupdate
then
	sh ${ROOT_DIR}/etc/volatile.cache
else	
	rm -f ${ROOT_DRI}/etc/volatile.cache ${ROOT_DIR}/etc/volatile.cache.build
	for file in `ls -1 "${CFGDIR}" | sort`; do
		apply_cfgfile "${CFGDIR}/${file}"
	done

	[ -e ${ROOT_DIR}/etc/volatile.cache.build ] && sync && mv ${ROOT_DIR}/etc/volatile.cache.build ${ROOT_DIR}/etc/volatile.cache
fi

if [ "${ROOT_DIR}" = "/" ] && [ -f /etc/ld.so.cache ] && [ ! -f /var/run/ld.so.cache ]
then
	ln -s /etc/ld.so.cache /var/run/ld.so.cache
fi
