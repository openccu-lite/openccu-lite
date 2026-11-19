################################################################################
#
# Azul java runtime - https://www.azul.com/downloads/?package=jre#zulu
#
################################################################################

JAVA_AZUL_VERSION = 21.54.201-ca-jre21.0.13.1
JAVA_AZUL_SITE = https://cdn.azul.com/zulu/bin
ifeq ($(call qstrip,$(BR2_ARCH)),aarch64)
JAVA_AZUL_SOURCE = zulu$(JAVA_AZUL_VERSION)-linux_aarch64.tar.gz
else ifeq ($(call qstrip,$(BR2_ARCH)),x86_64)
JAVA_AZUL_SOURCE = zulu$(JAVA_AZUL_VERSION)-linux_x64.tar.gz
endif
JAVA_AZUL_LICENSE = GPL
JAVA_AZUL_LICENSE_FILES = DISCLAIMER legal/java.base/LICENSE legal/java.base/ADDITIONAL_LICENSE_INFO legal/java.base/ASSEMBLY_EXCEPTION
# The JVM's font stack (AWT only): required when the configuration selects it, so a
# configuration without fontconfig/fonts (no AWT user on the box) can build.
JAVA_AZUL_DEPENDENCIES = \
	$(if $(BR2_PACKAGE_FONTCONFIG),fontconfig) \
	$(if $(BR2_PACKAGE_DEJAVU),dejavu) \
	$(if $(BR2_PACKAGE_LIBERATION),liberation)

define JAVA_AZUL_INSTALL_TARGET_CMDS
	$(INSTALL) -d -m 0755 $(TARGET_DIR)/opt/java-azul
	cp -a $(@D)/bin $(TARGET_DIR)/opt/java-azul/
	cp -a $(@D)/conf $(TARGET_DIR)/opt/java-azul/
	cp -a $(@D)/lib $(TARGET_DIR)/opt/java-azul/
	cp -a $(@D)/legal $(TARGET_DIR)/opt/java-azul/
	cp -a $(@D)/DISCLAIMER $(TARGET_DIR)/opt/java-azul/
	rm -f $(TARGET_DIR)/opt/java
	ln -s java-azul $(TARGET_DIR)/opt/java
endef

# B-353: target-finalize strips every executable and then patches its RUNPATH (fix-rpath target)
# on each build of the tree, and an incremental build does not reinstall this package. So a warm
# round stripped the JRE the previous round had already patched; strip re-lays a patched file (the
# segment patchelf added), and the patch then grew it again: 40 files under /opt/java-azul changed
# without a JRE update (bin/java 132,128 -> 134,128 bytes). The archive's files are put back first on
# every build, so strip and patchelf always start from them, and an unchanged JRE gives the same
# files as a fresh build. The hooks run before the strip and the RPATH step, in target-finalize's
# rule, where $(@D) is not the package's directory: JAVA_AZUL_DIR is.
define JAVA_AZUL_RESTORE_ARCHIVE_FILES
	for d in bin conf lib legal DISCLAIMER; do \
		cp -af $(JAVA_AZUL_DIR)/$$d $(TARGET_DIR)/opt/java-azul/ || exit 1; \
	done
endef
JAVA_AZUL_TARGET_FINALIZE_HOOKS += JAVA_AZUL_RESTORE_ARCHIVE_FILES

$(eval $(generic-package))
