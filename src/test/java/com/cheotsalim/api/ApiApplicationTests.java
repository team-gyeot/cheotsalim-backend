package com.cheotsalim.api;

import static org.mockito.Mockito.when;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.user;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.content;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import com.cheotsalim.api.config.SecurityConfig;
import com.cheotsalim.api.health.HealthController;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.webmvc.test.autoconfigure.WebMvcTest;
import org.springframework.context.annotation.Import;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.CannotGetJdbcConnectionException;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.web.servlet.MockMvc;

@WebMvcTest(HealthController.class)
@Import(SecurityConfig.class)
class ApiApplicationTests {

	@Autowired
	private MockMvc mockMvc;

	@MockitoBean
	private JdbcTemplate jdbcTemplate;

	@Test
	void healthChecksDatabaseWithoutAuthentication() throws Exception {
		when(jdbcTemplate.queryForObject("SELECT 1", Integer.class)).thenReturn(1);

		mockMvc.perform(get("/api/health"))
			.andExpect(status().isOk())
			.andExpect(content().json("{\"status\":\"UP\"}"));
	}

	@Test
	void databaseFailureReturnsUnavailableWithoutConnectionDetails() throws Exception {
		when(jdbcTemplate.queryForObject("SELECT 1", Integer.class))
			.thenThrow(new CannotGetJdbcConnectionException("private-host: password=secret"));

		mockMvc.perform(get("/api/health"))
			.andExpect(status().isServiceUnavailable())
			.andExpect(content().string("{\"status\":\"DOWN\"}"));
	}

	@Test
	void otherPathsRemainForbidden() throws Exception {
		mockMvc.perform(get("/api/private")).andExpect(status().isForbidden());
		mockMvc.perform(get("/api/private").with(user("test")))
			.andExpect(status().isForbidden());
		mockMvc.perform(get("/v3/api-docs")).andExpect(status().isForbidden());
	}

	@Test
	void healthDoesNotAllowWrites() throws Exception {
		mockMvc.perform(post("/api/health")).andExpect(status().isForbidden());
	}

}
